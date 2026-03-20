# Feature Specification: Security Audit Fixes

**Feature Branch**: `011-security-audit-fixes`
**Created**: 2026-03-20
**Status**: Draft
**Input**: Implement all security fixes identified in the security audit report (GitHub Issues #7–#10)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Ghost Bedrock Jobs from Race Condition (Priority: P1)

As the proxy operator, I need the system to never invoke a paid Bedrock job without first reserving a tracking slot, so that every job is accounted for and cancellable, and no untracked costs are incurred.

**Why this priority**: CRIT-1. Ghost Bedrock jobs incur real cost ($0.48–$13.50 each) with no record and no way to cancel. This is the only critical-severity finding in the audit.

**Independent Test**: Submit concurrent video generation requests that exceed the per-key concurrent job limit. Verify that requests rejected by the limit never trigger a Bedrock invocation, and that no "ghost" jobs appear in Bedrock's async invoke list without a corresponding database record.

**Acceptance Scenarios**:

1. **Given** a key at its concurrent job limit, **When** a new video request arrives, **Then** the system returns HTTP 429 without invoking Bedrock
2. **Given** a key below its concurrent limit, **When** a video request arrives and the DB slot is reserved, **Then** Bedrock is invoked and the DB record is updated with the invocation ARN
3. **Given** a reserved DB slot, **When** the Bedrock invocation fails, **Then** the DB record is marked as failed and the slot is released

---

### User Story 2 - Restrict IAM Permissions to Required Models Only (Priority: P1)

As the proxy operator, I need Bedrock IAM permissions scoped to only the model families actually used, so that a compromised instance cannot invoke arbitrary foundation models across all regions.

**Why this priority**: HIGH-3. The current `foundation-model/*` wildcard across 12 regions allows any Bedrock model to be invoked directly, bypassing the LiteLLM allowlist.

**Independent Test**: After applying the IAM change, attempt to invoke an unlisted model (e.g., Meta Llama) via boto3 on the instance. Verify it is denied by IAM. Verify all configured models in litellm-config.yaml still work.

**Acceptance Scenarios**:

1. **Given** the updated IAM policy, **When** an allowed model (e.g., anthropic.claude-*) is invoked, **Then** the request succeeds
2. **Given** the updated IAM policy, **When** an unlisted model family is invoked directly via boto3, **Then** IAM denies the request

---

### User Story 3 - Enforce Request Body Size Limits (Priority: P1)

As the proxy operator, I need the sidecar to reject oversized request bodies before parsing, so that a large payload cannot exhaust the sidecar's 256MB memory limit and cause a denial of service.

**Why this priority**: HIGH-4. A 20-shot request with maximum-size images (280MB) exceeds the sidecar's MemoryMax and triggers an OOM kill.

**Independent Test**: Send a request with a body exceeding 40MB to any sidecar endpoint. Verify HTTP 413 is returned without the request being fully read into memory.

**Acceptance Scenarios**:

1. **Given** a request body exceeding 40MB, **When** submitted to any sidecar endpoint, **Then** the system returns HTTP 413 (Request Entity Too Large) without processing the body
2. **Given** a legitimate 20-shot request with small images (under 40MB total), **When** submitted, **Then** the request is accepted and processed normally

---

### User Story 4 - Verify Cloudflared Binary Integrity (Priority: P2)

As the proxy operator, I need the cloudflared binary verified by SHA256 checksum during bootstrap, so that a tampered binary cannot be installed via a man-in-the-middle or compromised download.

**Why this priority**: HIGH-1. The current `--version` string check is trivially spoofable. A compromised cloudflared could intercept all tunnel traffic.

**Independent Test**: Modify the expected checksum to a wrong value and run bootstrap. Verify it aborts before installing the binary.

**Acceptance Scenarios**:

1. **Given** a valid cloudflared download, **When** the checksum matches the published SHA256, **Then** installation proceeds
2. **Given** a tampered or corrupted download, **When** the checksum does not match, **Then** bootstrap aborts with a clear error message

---

### User Story 5 - Sanitize Error Messages Returned to Clients (Priority: P2)

As the proxy operator, I need Bedrock error details logged server-side but not returned to API clients, so that internal infrastructure details (ARNs, account IDs, regions) are not leaked.

**Why this priority**: MED-2. Verbatim AWS error messages expose internal details to any authenticated caller.

**Independent Test**: Trigger a Bedrock error (e.g., invalid model parameter) and verify the HTTP response contains only a generic error message, while the full error is recorded in server logs.

**Acceptance Scenarios**:

1. **Given** a Bedrock ClientError, **When** returned to the caller, **Then** the response contains a generic message (e.g., "Service request failed") without AWS-specific details
2. **Given** a Bedrock ClientError, **When** logged server-side, **Then** the full error message including ARN and region is preserved in the journal

---

### User Story 6 - Scope SSM PutParameter to Database Password Only (Priority: P2)

As the proxy operator, I need the instance role's SSM write permission limited to the database password parameter only, so that a compromised instance cannot overwrite the master key or tunnel token for persistence.

**Why this priority**: MED-3. The instance only writes `/rockport/db-password` during bootstrap; the other two parameters are never written by the instance.

**Independent Test**: After applying the IAM change, attempt `aws ssm put-parameter` for `/rockport/master-key` from the instance. Verify it is denied.

**Acceptance Scenarios**:

1. **Given** the updated IAM policy, **When** the instance writes to `/rockport/db-password`, **Then** the operation succeeds
2. **Given** the updated IAM policy, **When** the instance attempts to write to `/rockport/master-key` or `/rockport/tunnel-token`, **Then** IAM denies the request

---

### User Story 7 - Verify Deploy Artifact Integrity (Priority: P2)

As the proxy operator, I need deploy artifacts verified by checksum after downloading from S3, so that tampered artifacts cannot be installed on the instance.

**Why this priority**: MED-8. Both the deployer and CI pipeline have S3 write access; a compromised credential could replace the artifact.

**Independent Test**: Upload an artifact with a mismatched checksum to S3 and run bootstrap. Verify it aborts.

**Acceptance Scenarios**:

1. **Given** a valid artifact and matching checksum in S3, **When** bootstrap downloads and verifies, **Then** extraction proceeds normally
2. **Given** a tampered artifact with mismatched checksum, **When** bootstrap downloads and verifies, **Then** bootstrap aborts with an error

---

### User Story 8 - Enforce Claude-Only Key Restrictions on Video Endpoints (Priority: P2)

As the proxy operator, I need video endpoints to reject requests from claude-only API keys, so that keys intended for text-only usage cannot generate video content and incur video costs.

**Why this priority**: NEW finding. The image API already enforces this restriction; the video API does not, creating an inconsistent authorization gap.

**Independent Test**: Create a claude-only key and attempt a video generation request. Verify HTTP 403 is returned.

**Acceptance Scenarios**:

1. **Given** a claude-only API key, **When** a video generation request is submitted, **Then** the system returns HTTP 403 with a message indicating the key does not have video access
2. **Given** a standard API key (not claude-only), **When** a video generation request is submitted, **Then** the request is processed normally

---

### User Story 9 - Add Seed Range Validation to Video Requests (Priority: P3)

As the proxy operator, I need the video API's seed parameter validated to the same range as the image API (0–2,147,483,646), so that out-of-range values are caught before reaching Bedrock.

**Why this priority**: LOW-1. Trivial fix for consistency. Currently Bedrock would reject bad values but the error message leakage (MED-2) makes client-side validation preferable.

**Independent Test**: Submit a video request with seed=-1 and seed=2147483647. Verify both return HTTP 422 validation errors.

**Acceptance Scenarios**:

1. **Given** a seed value within range (0–2,147,483,646), **When** submitted, **Then** the request is accepted
2. **Given** a seed value outside the range, **When** submitted, **Then** HTTP 422 is returned with a validation error

---

### User Story 10 - Secure Bootstrap Log File Permissions (Priority: P3)

As the proxy operator, I need the bootstrap log file created with restricted permissions (owner-only), so that other users on the instance cannot read infrastructure details from the log.

**Why this priority**: MED-6. Trivial one-line fix. The log contains infrastructure setup details that should not be world-readable.

**Independent Test**: After bootstrap, verify the log file permissions are 600 (owner read/write only).

**Acceptance Scenarios**:

1. **Given** bootstrap runs, **When** the log file is created, **Then** its permissions are 600 (rw-------)

---

### User Story 11 - Generate Hashed Pip Requirements Lock File (Priority: P3)

As the proxy operator, I need Python dependencies installed with hash verification, so that a compromised PyPI package cannot be installed during bootstrap.

**Why this priority**: MED-1. Supply chain risk. Currently pip installs version-pinned packages but does not verify integrity via hashes.

**Independent Test**: Verify bootstrap uses `pip install --require-hashes -r requirements.lock` and that the lock file contains SHA256 hashes for all packages including transitive dependencies.

**Acceptance Scenarios**:

1. **Given** a valid requirements lock file with hashes, **When** bootstrap runs pip install, **Then** all packages are verified against their hashes before installation
2. **Given** a tampered package on PyPI with a different hash, **When** pip attempts to install it, **Then** installation fails with a hash mismatch error

---

### User Story 12 - Add CloudTrail Logging via Terraform (Priority: P3)

As the proxy operator, I need AWS API activity logged via CloudTrail, so that security-relevant events (IAM changes, SSM usage, S3 access) are captured for incident detection and forensics.

**Why this priority**: MED-7. The audit noted that preventive controls are strong but detective controls are absent. CloudTrail fills this gap.

**Independent Test**: After deploying, verify the CloudTrail trail exists and is logging management events. Trigger an SSM command and verify it appears in CloudTrail logs.

**Acceptance Scenarios**:

1. **Given** the Terraform is applied, **When** an AWS API call is made (e.g., SSM SendCommand), **Then** the event is recorded in CloudTrail within 15 minutes
2. **Given** the CloudTrail trail, **When** queried for recent events, **Then** management events from the rockport account are present

---

### User Story 13 - Scope SSM Command Documents in Deployer IAM (Priority: P3)

As the proxy operator, I need the deployer's SSM document permissions scoped to only the documents it actually uses, so that a compromised deployer credential cannot execute arbitrary SSM documents.

**Why this priority**: LOW-2. Minor tightening of least-privilege. The instance-level tag constraint already limits which instances can be targeted.

**Independent Test**: Attempt to use a non-allowed SSM document (e.g., `AWS-ApplyPatchBaseline`) via the deployer role. Verify it is denied.

**Acceptance Scenarios**:

1. **Given** the updated IAM policy, **When** the deployer uses `AWS-RunShellScript`, **Then** the operation succeeds
2. **Given** the updated IAM policy, **When** the deployer uses an unlisted SSM document, **Then** IAM denies the request

---

### User Story 14 - Add DenyNonSSL to State Bucket During Init (Priority: P3)

As the proxy operator, I need the Terraform state bucket to enforce TLS-only access from creation, so that there is no window where unencrypted access is possible.

**Why this priority**: LOW-4. The AWS SDK uses HTTPS by default so the practical risk is negligible, but defense-in-depth is good practice.

**Independent Test**: Run `rockport.sh init` in a clean environment. Verify the state bucket has a DenyNonSSL bucket policy immediately after creation.

**Acceptance Scenarios**:

1. **Given** `rockport.sh init` creates a new state bucket, **When** the bucket is created, **Then** a DenyNonSSL bucket policy is attached before any state is written

---

### Edge Cases

- What happens when the DB is unreachable during the CRIT-1 slot reservation? The system must fail closed (return 503, do not invoke Bedrock)
- What happens when the cloudflared SHA256 checksum file is unavailable from GitHub? Bootstrap must abort rather than skipping verification
- What happens when CloudTrail delivery to S3 fails? An alarm should notify the operator
- What happens when a request body is exactly at the 40MB limit? It should be accepted (the limit is exclusive)
- What happens when the deploy artifact checksum file is missing from S3? Bootstrap must abort rather than skipping verification

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST reserve a database tracking slot before invoking any paid Bedrock operation
- **FR-002**: System MUST release the database slot and mark it as failed if the Bedrock invocation fails
- **FR-003**: System MUST return HTTP 429 without invoking Bedrock when the concurrent job limit is reached
- **FR-004**: Bedrock IAM policy MUST enumerate specific model family patterns per region instead of using `foundation-model/*`
- **FR-005**: Sidecar MUST reject request bodies exceeding 40MB with HTTP 413 before fully reading the body into memory
- **FR-006**: Bootstrap MUST verify the cloudflared binary's SHA256 checksum against the published checksum file and abort on mismatch
- **FR-007**: Sidecar MUST log full Bedrock error details server-side and return only generic error messages to clients
- **FR-008**: Instance IAM role MUST only have `ssm:PutParameter` permission for the `/rockport/db-password` parameter
- **FR-009**: Bootstrap MUST verify deploy artifact integrity via checksum and abort on mismatch
- **FR-010**: Video endpoints MUST reject requests from claude-only API keys with HTTP 403
- **FR-011**: Video API seed parameter MUST be validated to the range 0–2,147,483,646
- **FR-012**: Bootstrap log file MUST be created with permissions 600 (owner read/write only)
- **FR-013**: Bootstrap MUST install Python packages using hash-verified requirements (`--require-hashes`)
- **FR-014**: Terraform MUST provision a CloudTrail trail logging management events to an S3 bucket
- **FR-015**: Deployer IAM MUST scope SSM document permissions to `AWS-RunShellScript` and `AWS-StartInteractiveCommand` only
- **FR-016**: `rockport.sh init` MUST attach a DenyNonSSL bucket policy to the state bucket at creation time

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero ghost Bedrock jobs can be created — every invocation has a corresponding database record or is never submitted
- **SC-002**: A compromised instance can only invoke the specific model families configured in litellm-config.yaml, not arbitrary Bedrock models
- **SC-003**: No request exceeding 40MB reaches the sidecar's application layer
- **SC-004**: No AWS-internal identifiers (ARNs, account IDs, region names) appear in any client-facing error response
- **SC-005**: All binary downloads (cloudflared) and deploy artifacts are cryptographically verified before use
- **SC-006**: All 14 fixes pass their independent acceptance tests as defined in each user story
- **SC-007**: Existing functionality (chat, image generation, video generation, admin CLI) continues to work without regression after all fixes are applied

## Assumptions

- The cloudflared GitHub releases page continues to publish `.sha256sum` files alongside binaries
- The 40MB body size limit accommodates all legitimate single-image use cases. Ray2 images are max 25MB raw (~33MB base64-encoded). Two Ray2 images (start + end frame) could reach ~66MB base64 but individual fields are already capped at 35MB by Pydantic max_length. The 40MB body limit catches abuse cases while per-field validation handles legitimate multi-image requests
- CloudTrail costs are acceptable for the project (management events only, typically low volume for a single-instance project)
- The hashed requirements lock file will need to be regenerated when sidecar dependencies are updated
- Scoping Bedrock IAM to specific model families covers: `anthropic.claude-*`, `amazon.nova-*`, `amazon.titan-*`, `deepseek.*`, `qwen.*`, `moonshotai.*`, `stability.*`, `luma.*`
