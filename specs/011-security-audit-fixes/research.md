# Research: Security Audit Fixes

**Branch**: `011-security-audit-fixes` | **Date**: 2026-03-20

## R1: CRIT-1 Race Condition — Slot Reservation Before Bedrock

**Decision**: Make `invocation_arn` nullable in `insert_job_if_under_limit`, reserve the DB slot first with a placeholder status, call Bedrock second, then update the ARN. On Bedrock failure, mark the job as failed.

**Rationale**: The current schema has `invocation_arn TEXT UNIQUE NOT NULL` (db.py line 60). The fix requires the slot to exist before the ARN is known. Making it nullable lets us reserve first, update after. The `UNIQUE` constraint still prevents duplicates. The advisory lock (`pg_advisory_xact_lock`) already prevents concurrent over-insertion per key.

**Alternatives considered**:
- Generate a placeholder ARN string (e.g., `pending-{uuid}`) — rejected because it pollutes the unique index and complicates status queries
- Two-phase insert (reserve row, then update) — this IS the chosen approach, with nullable ARN as the mechanism

**Implementation detail**: After `insert_job_if_under_limit` returns the job dict, call `start_async_invoke`. If it succeeds, update the row with the real ARN. If it fails, call a new `mark_job_failed` function. The DB status for a reserved-but-not-yet-started job should be `"pending"` rather than `"in_progress"`.

---

## R2: Bedrock IAM Model Scoping

**Decision**: Replace `foundation-model/*` with explicit model-family patterns derived from litellm-config.yaml and the video sidecar configuration.

**Rationale**: The current wildcard grants access to ALL Bedrock foundation models. Scoping to specific families limits blast radius if the instance role is compromised.

**Model families requiring IAM access**:

| Family | ARN Pattern | Regions |
|--------|-------------|---------|
| Anthropic Claude | `anthropic.claude-*` | All EU cross-region (eu-west-1, eu-west-2, eu-west-3, eu-central-1, eu-central-2, eu-north-1, eu-south-1, eu-south-2) |
| Amazon Nova (chat) | `amazon.nova-*` | EU cross-region |
| Amazon Titan Image | `amazon.titan-image-generator-*` | us-west-2 |
| DeepSeek | `deepseek.*` | EU cross-region |
| Qwen | `qwen.*` | EU cross-region |
| Moonshot Kimi | `moonshotai.*` | EU cross-region |
| Stability AI | `stability.*` | us-west-2 |
| Luma Ray2 | `luma.*` | us-west-2 |

**Note**: The `bedrock_async_invoke` policy (main.tf lines 127-155) also needs scoping. It currently duplicates `bedrock:InvokeModel` which is redundant with the `bedrock_invoke` policy. The async-specific actions (`GetAsyncInvoke`, `StartAsyncInvoke`, `ListAsyncInvokes`) only need Nova Reel and Luma Ray2 models.

---

## R3: FastAPI Body Size Middleware

**Decision**: Add a custom ASGI middleware that reads the `Content-Length` header and rejects requests over 40MB with HTTP 413. For chunked transfers (no Content-Length), stream-count bytes and abort at threshold.

**Rationale**: FastAPI/Starlette has no built-in body size limit. uvicorn has `--limit-request-line` and `--limit-request-field-size` but no body size limit. A lightweight middleware is the standard approach.

**Alternatives considered**:
- nginx reverse proxy with `client_max_body_size` — rejected because adding nginx violates scope containment and LiteLLM-First principles
- Starlette `BaseHTTPMiddleware` — rejected because it buffers the entire body; a raw ASGI middleware can check Content-Length without reading

**40MB rationale**: Largest legitimate request is Ray2 with start + end images (2 × 25MB as data URIs ≈ 2 × 33MB base64 + metadata). 40MB raw body accommodates single-image requests comfortably. Multi-shot with 20 × 14MB images would be ~280MB which is clearly abusive.

---

## R4: Cloudflared Checksum Verification

**Decision**: Download the `.sha256sum` file from the same GitHub release URL, verify with `sha256sum -c`, and abort on mismatch.

**Rationale**: GitHub releases for cloudflared publish `cloudflared-linux-amd64.sha256sum` alongside the binary. This is the standard verification method.

**Implementation**: After downloading the binary, download `https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64.sha256sum`, rename the binary to match the expected filename, and run `sha256sum -c`.

---

## R5: Error Message Sanitization

**Decision**: Log the full Bedrock error (including ARN, region, account info) via `logger.error()`, return a generic error message to the client with an error reference ID for correlation.

**Rationale**: The current pattern `f"...failed: {error_msg}"` passes raw AWS error strings to clients. These can contain ARNs (with account IDs), region names, and internal error codes.

**Generic messages by error type**:
- Bedrock ClientError → `"The upstream service returned an error. Reference: {uuid}"`
- Bedrock throttling → `"The upstream service is temporarily overloaded. Please retry."`
- Generic Exception → `"An unexpected error occurred. Reference: {uuid}"`

The reference UUID is logged alongside the full error for operator correlation.

---

## R6: Deploy Artifact Checksum

**Decision**: Generate a SHA256 checksum file during CI/CD artifact creation, upload it alongside the artifact to S3, and verify in bootstrap before extraction.

**Rationale**: The artifact tarball is downloaded from S3 without integrity verification. Both the deployer and CI have `s3:PutObject` permission, so a compromised credential could replace the artifact.

**Implementation**: In the deploy workflow, `sha256sum rockport-artifact.tar.gz > rockport-artifact.tar.gz.sha256`. Upload both to S3. In bootstrap, download both and verify with `sha256sum -c`.

---

## R7: Hashed Pip Requirements Lock File

**Decision**: Generate a `requirements.lock` file with `pip-compile --generate-hashes` and use `pip install --require-hashes -r requirements.lock` in bootstrap.

**Rationale**: Currently bootstrap installs packages by name without referencing `sidecar/requirements.txt` or verifying hashes. A lock file with hashes provides supply chain integrity.

**Implementation**: Two lock files needed:
1. `sidecar/requirements.lock` — for sidecar dependencies (psycopg2-binary, Pillow, httpx, pydantic, uvicorn, fastapi, boto3)
2. LiteLLM is installed separately with its own version pin — generating a full lock for litellm[proxy] and all transitive deps is impractical (hundreds of packages). Keep version-pinned install for LiteLLM; add `--require-hashes` only for sidecar deps.

**Alternatives considered**:
- Full lock for everything including LiteLLM — rejected because litellm[proxy] has 100+ transitive deps that change frequently; maintaining the lock would be a constant burden
- pip-audit for vulnerability checking — orthogonal; can be added later

---

## R8: CloudTrail Configuration

**Decision**: Create a CloudTrail trail in eu-west-2 logging management events to a dedicated S3 bucket with a 90-day lifecycle.

**Rationale**: The audit noted strong preventive controls but absent detective controls. CloudTrail provides an audit trail for IAM, SSM, S3, and Bedrock API calls.

**Cost**: ~$2/month for management events in a single-account, single-region setup. S3 storage is negligible with 90-day lifecycle.

**Implementation**: New `terraform/cloudtrail.tf` with:
- S3 bucket (`rockport-cloudtrail-{account}`) with encryption, versioning, DenyNonSSL, 90-day lifecycle
- CloudTrail trail (management events only, no data events to avoid high volume)
- Deployer needs `cloudtrail:CreateTrail`, `cloudtrail:StartLogging`, `cloudtrail:UpdateTrail`, `cloudtrail:DescribeTrails`, `cloudtrail:GetTrailStatus` permissions
