# Tasks: Security Audit Fixes

**Input**: Design documents from `/specs/011-security-audit-fixes/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: No new project initialization needed. This phase validates the current state before making changes.

- [x] T001 Read and understand the current video generation flow in sidecar/video_api.py (lines 580-670) to confirm CRIT-1 race condition
- [x] T002 Read and understand the current DB schema and insert_job_if_under_limit in sidecar/db.py (lines 250-303)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: DB schema change required before the CRIT-1 fix can be implemented. Error sanitization helper needed before endpoint changes.

**CRITICAL**: US1 (CRIT-1 fix) depends on the DB schema change completing first.

- [x] T003 Make invocation_arn nullable and change default status to 'pending' in the rockport_video_jobs table schema in sidecar/db.py (line 60: change `TEXT UNIQUE NOT NULL` to `TEXT UNIQUE`, line 58: change default from `in_progress` to `pending`). Note: the table is created via `CREATE TABLE IF NOT EXISTS` so existing instances need a one-time `ALTER TABLE rockport_video_jobs ALTER COLUMN invocation_arn DROP NOT NULL, ALTER COLUMN status SET DEFAULT 'pending'` — add this as a migration block in db.py's ensure_tables() that runs idempotently
- [x] T004 Add update_job_arn(job_id, invocation_arn) function to sidecar/db.py that sets invocation_arn and status='in_progress' for a given job_id
- [x] T005 Add mark_job_failed(job_id, error_message) function to sidecar/db.py that sets status='failed' and stores the error message for a given job_id

**Checkpoint**: DB layer ready for CRIT-1 fix and error sanitization work.

---

## Phase 3: User Story 1 — Prevent Ghost Bedrock Jobs (Priority: P1) MVP

**Goal**: Eliminate the race condition where Bedrock is invoked before the concurrent job limit is checked, preventing untracked ghost jobs.

**Independent Test**: Submit concurrent video requests exceeding the per-key limit. Verify rejected requests never invoke Bedrock.

### Implementation for User Story 1

- [x] T006 [US1] Restructure create_video() in sidecar/video_api.py to call db.insert_job_if_under_limit() BEFORE client.start_async_invoke() — pass invocation_arn=None for the initial reservation
- [x] T007 [US1] After successful start_async_invoke() in sidecar/video_api.py, call db.update_job_arn() to set the real invocation ARN and transition status from 'pending' to 'in_progress'
- [x] T008 [US1] Add error handling in sidecar/video_api.py: if start_async_invoke() raises ClientError after DB slot is reserved, call db.mark_job_failed() to release the slot and return 502 to the client
- [x] T009 [US1] Ensure that when insert_job_if_under_limit returns None (limit reached), the function returns HTTP 429 immediately without calling start_async_invoke() in sidecar/video_api.py
- [x] T010 [US1] Handle DB unreachable edge case in sidecar/video_api.py: if the DB slot reservation fails with a connection error, return HTTP 503 without invoking Bedrock (fail closed)

**Checkpoint**: Ghost Bedrock jobs are impossible. Every invocation has a DB record or is never submitted.

---

## Phase 4: User Story 2 — Restrict IAM to Required Models (Priority: P1)

**Goal**: Replace foundation-model/* wildcard with specific model family patterns.

**Independent Test**: Verify configured models work; verify unlisted models are denied by IAM.

### Implementation for User Story 2

- [x] T011 [US2] In terraform/main.tf bedrock_invoke policy (lines 59-81), replace `foundation-model/*` with specific model ARN patterns per region: `anthropic.claude-*`, `amazon.nova-*`, `amazon.titan-*`, `deepseek.*`, `qwen.*`, `moonshotai.*` for EU cross-region; `stability.*`, `luma.*`, `amazon.nova-*`, `amazon.titan-*` for us-west-2; `amazon.nova-*` for us-east-1. Keep `inference-profile/*` unchanged as cross-region profiles need it
- [x] T012 [US2] In terraform/main.tf bedrock_async_invoke policy (lines 127-155), scope foundation-model resources to `amazon.nova-*` for us-east-1 and `luma.*` plus `amazon.nova-*` for us-west-2 (these are the only async/video models)
- [x] T013 [US2] Run terraform plan to verify the IAM changes produce the expected diff and no existing model access is inadvertently removed

**Checkpoint**: IAM permissions scoped to only the model families actually in use.

---

## Phase 5: User Story 3 — Enforce Request Body Size Limits (Priority: P1)

**Goal**: Reject oversized request bodies before they exhaust the sidecar's 256MB memory limit.

**Independent Test**: Send a >40MB body to any sidecar endpoint and verify HTTP 413 is returned.

### Implementation for User Story 3

- [x] T014 [US3] Add a raw ASGI middleware class to sidecar/video_api.py (before the FastAPI app routes) that checks the Content-Length header against a 40MB limit (exclusive — exactly 40MB is accepted, over 40MB is rejected) and returns HTTP 413 if exceeded, without reading the body
- [x] T015 [US3] In the same middleware, handle chunked transfer encoding (no Content-Length) by counting bytes as they stream and aborting with HTTP 413 if the 40MB threshold is crossed
- [x] T016 [US3] Register the body size middleware on the FastAPI app in sidecar/video_api.py (after line 120 where the app is created)

**Checkpoint**: No request over 40MB reaches the application layer.

---

## Phase 6: User Story 4 — Verify Cloudflared Binary Integrity (Priority: P2)

**Goal**: Verify cloudflared binary via SHA256 checksum during bootstrap.

**Independent Test**: Corrupt the expected checksum and confirm bootstrap aborts.

### Implementation for User Story 4

- [x] T017 [US4] In scripts/bootstrap.sh (after the cloudflared binary download at line 264), add a curl command to download the corresponding .sha256sum file from the same GitHub release URL
- [x] T018 [US4] In scripts/bootstrap.sh, rename the downloaded binary to match the filename expected in the .sha256sum file, then run `sha256sum -c` to verify. Abort bootstrap with a clear error if verification fails
- [x] T019 [US4] Remove the old version-string-only verification (`cloudflared --version | grep`) in scripts/bootstrap.sh (line 268) since SHA256 checksum is a stronger guarantee

**Checkpoint**: Cloudflared binary is cryptographically verified before installation.

---

## Phase 7: User Story 5 — Sanitize Error Messages (Priority: P2)

**Goal**: Log full Bedrock errors server-side, return only generic messages to clients.

**Independent Test**: Trigger a Bedrock error and verify the response contains no AWS identifiers.

### Implementation for User Story 5

- [x] T020 [P] [US5] In sidecar/video_api.py, replace all ClientError exception handlers (around lines 636-642) to log the full error with `logger.error()` including a generated reference UUID, then return a generic message like "Video generation request failed. Reference: {uuid}" without the raw AWS error_msg
- [x] T021 [P] [US5] In sidecar/image_api.py, replace all ClientError exception handlers (lines 279, 335, 441) with the same pattern: log full error with reference UUID, return generic message to client
- [x] T022 [US5] In both sidecar/video_api.py and sidecar/image_api.py, also sanitize generic Exception handlers to return "An unexpected error occurred. Reference: {uuid}" instead of including exception type names

**Checkpoint**: No AWS ARNs, account IDs, or region names appear in any client-facing error.

---

## Phase 8: User Story 6 — Scope SSM PutParameter (Priority: P2)

**Goal**: Restrict instance role's SSM write permission to /rockport/db-password only.

**Independent Test**: Attempt to write /rockport/master-key from the instance and verify IAM denies it.

### Implementation for User Story 6

- [x] T023 [US6] In terraform/main.tf ssm_parameters policy (lines 105-125), split the statement into two: one for GetParameter on all three paths, one for PutParameter on only `arn:aws:ssm:*:*:parameter/rockport/db-password`
- [x] T024 [US6] Run terraform plan to verify the change correctly narrows PutParameter while preserving GetParameter on all three paths

**Checkpoint**: Instance can only write the DB password parameter.

---

## Phase 9: User Story 7 — Verify Deploy Artifact Integrity (Priority: P2)

**Goal**: Verify deploy artifacts via checksum before extraction.

**Independent Test**: Upload a mismatched checksum and confirm bootstrap aborts.

### Implementation for User Story 7

- [x] T025 [US7] In the CI/CD deploy workflow (.github/workflows/deploy.yml), after creating the artifact tarball, generate a SHA256 checksum file and upload both to S3
- [x] T026 [US7] In scripts/bootstrap.sh (lines 188-196), after downloading the artifact tarball from S3, also download the .sha256 checksum file and verify with `sha256sum -c`. Abort if verification fails or if the checksum file is missing

**Checkpoint**: Deploy artifacts are cryptographically verified before use.

---

## Phase 10: User Story 8 — Claude-Only Key Enforcement on Video (Priority: P2)

**Goal**: Video endpoints reject requests from claude-only API keys.

**Independent Test**: Use a claude-only key for video generation and verify HTTP 403.

### Implementation for User Story 8

- [x] T027 [US8] In sidecar/video_api.py create_video() function, add an is_claude_only_key(auth) check after the authenticate() call (mirroring image_api.py lines 93-100), returning HTTP 403 with message "This endpoint requires an unrestricted API key. Keys created with --claude-only cannot access video generation services."
- [x] T028 [US8] Add the same claude-only check to get_video_status() and list_videos() endpoints in sidecar/video_api.py to ensure consistent authorization across all video endpoints

**Checkpoint**: Claude-only keys are blocked from all video endpoints, consistent with image API behavior.

---

## Phase 11: User Story 9 — Seed Range Validation (Priority: P3)

**Goal**: Validate video API seed parameter to range 0–2,147,483,646.

**Independent Test**: Submit seed=-1 and seed=2147483647, verify HTTP 422.

### Implementation for User Story 9

- [x] T029 [US9] In sidecar/video_api.py VideoGenerationRequest model (line 198), change `seed: int | None = None` to `seed: int | None = Field(default=None, ge=0, le=2_147_483_646)` to match the image API's validation

**Checkpoint**: Out-of-range seed values are rejected at the API layer.

---

## Phase 12: User Story 10 — Secure Bootstrap Log Permissions (Priority: P3)

**Goal**: Bootstrap log file created with 600 permissions.

**Independent Test**: After bootstrap, verify log file is rw------- (600).

### Implementation for User Story 10

- [x] T030 [US10] In scripts/bootstrap.sh (before the exec redirect on line 6), add `touch "$LOG_FILE" && chmod 600 "$LOG_FILE"` to create the file with restricted permissions before any content is written

**Checkpoint**: Bootstrap log is not world-readable.

---

## Phase 13: User Story 11 — Hashed Pip Requirements (Priority: P3)

**Goal**: Install sidecar Python packages with hash verification.

**Independent Test**: Verify bootstrap uses --require-hashes and the lock file contains SHA256 hashes.

### Implementation for User Story 11

- [x] T031 [US11] First update sidecar/requirements.txt to use exact version pins (`==`) instead of lower bounds (`>=`), then generate sidecar/requirements.lock by running `pip-compile --generate-hashes sidecar/requirements.txt -o sidecar/requirements.lock` to produce the lock file with all transitive dependencies pinned to exact versions with SHA256 hashes
- [x] T032 [US11] In scripts/bootstrap.sh (line 215), replace the direct `pip3.11 install psycopg2-binary Pillow httpx` with `pip3.11 install --require-hashes -r /tmp/rockport-artifact/sidecar/requirements.lock` to use the hashed lock file

**Checkpoint**: All sidecar pip packages are verified by hash before installation.

---

## Phase 14: User Story 12 — Add CloudTrail (Priority: P3)

**Goal**: AWS API activity logged via CloudTrail for incident detection.

**Independent Test**: Verify CloudTrail trail exists and logs management events.

### Implementation for User Story 12

- [x] T033 [US12] Create terraform/cloudtrail.tf with: S3 bucket (rockport-cloudtrail-{account}) with SSE, DenyNonSSL bucket policy, 90-day lifecycle rule, CloudTrail write access bucket policy, and aws_cloudtrail resource for management events only (no data events) writing to the bucket in eu-west-2
- [x] T034 [US12] In terraform/cloudtrail.tf, add a CloudWatch metric alarm that fires when CloudTrail log delivery fails (use the `CallCount` metric for `PutObject` on the trail bucket, or a CloudTrail-specific SNS notification for delivery failures)
- [x] T035 [US12] Add CloudTrail-related IAM permissions (cloudtrail:CreateTrail, StartLogging, UpdateTrail, DescribeTrails, GetTrailStatus, DeleteTrail) to the deployer policy in terraform/deployer-policies/monitoring-storage.json
- [x] T036 [US12] Run terraform plan to verify CloudTrail resources are created correctly

**Checkpoint**: Management events are logged to CloudTrail for audit and incident detection.

---

## Phase 15: User Story 13 — Scope SSM Documents (Priority: P3)

**Goal**: Deployer SSM document permissions scoped to AWS-RunShellScript and AWS-StartInteractiveCommand only.

**Independent Test**: Attempt an unlisted SSM document via deployer role and verify denial.

### Implementation for User Story 13

- [x] T037 [US13] In terraform/deployer-policies/iam-ssm.json (lines 119-126), replace `arn:aws:ssm:*::document/*` with two specific ARNs: `arn:aws:ssm:*::document/AWS-RunShellScript` and `arn:aws:ssm:*::document/AWS-StartInteractiveCommand`

**Checkpoint**: Deployer can only use the two SSM documents it actually needs.

---

## Phase 16: User Story 14 — DenyNonSSL on State Bucket (Priority: P3)

**Goal**: State bucket enforces TLS-only access from creation.

**Independent Test**: Run rockport.sh init and verify bucket has DenyNonSSL policy.

### Implementation for User Story 14

- [x] T038 [US14] In scripts/rockport.sh ensure_state_backend function (lines 415-451), after creating the bucket and enabling versioning/encryption, add an `aws s3api put-bucket-policy` call that attaches a DenyNonSSL policy (deny s3:* where aws:SecureTransport is false), matching the pattern used in terraform/s3.tf for the video buckets

**Checkpoint**: State bucket enforces HTTPS from the moment of creation.

---

## Phase 17: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and documentation.

- [x] T039 Update CLAUDE.md to document the new CloudTrail resource, the changed video job status flow (pending → in_progress → completed/failed), and the body size limit
- [x] T040 Run the existing smoke test (tests/smoke-test.sh) to verify no regressions in chat, image generation, and video generation after all changes
- [x] T041 Review security-audit-report.md and verify each "Fix required" item has been addressed by the corresponding task

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — read-only orientation
- **Foundational (Phase 2)**: No external dependencies — DB schema changes in db.py
- **US1 CRIT-1 (Phase 3)**: Depends on Phase 2 (DB functions must exist before video_api.py changes)
- **US2 IAM (Phase 4)**: Independent — Terraform only, no code dependencies
- **US3 Body Size (Phase 5)**: Independent — new middleware, no dependencies
- **US4 Cloudflared (Phase 6)**: Independent — bootstrap.sh only
- **US5 Error Sanitization (Phase 7)**: Independent — can run in parallel with other sidecar changes on different code paths
- **US6 SSM Scope (Phase 8)**: Independent — Terraform only
- **US7 Artifact Checksum (Phase 9)**: Independent — CI/CD + bootstrap.sh
- **US8 Claude-Only (Phase 10)**: Should follow US1 (Phase 3) since both modify create_video()
- **US9 Seed Validation (Phase 11)**: Independent — single line change
- **US10 Log Permissions (Phase 12)**: Independent — bootstrap.sh only
- **US11 Pip Hashing (Phase 13)**: Independent — new lock file + bootstrap.sh
- **US12 CloudTrail (Phase 14)**: Independent — new Terraform file
- **US13 SSM Documents (Phase 15)**: Independent — deployer policy only
- **US14 State Bucket (Phase 16)**: Independent — rockport.sh only
- **Polish (Phase 17)**: Depends on all previous phases

### User Story Dependencies

- **US1 (P1)**: Depends on Foundational (Phase 2). Blocks US8 (both touch create_video).
- **US2–US7 (P1/P2)**: All independent of each other and US1
- **US8 (P2)**: Should follow US1 to avoid merge conflicts in create_video()
- **US9–US14 (P3)**: All independent of each other and all other stories

### Parallel Opportunities

After Phase 2 completes, the following can run in parallel:
- **Group A (sidecar)**: US1 → then US8 (same function)
- **Group B (sidecar)**: US3 (body size middleware), US5 (error sanitization), US9 (seed validation) — different code paths
- **Group C (Terraform)**: US2 → then US6 (both modify main.tf, must be sequential), US12, US13 — US12 and US13 are in different files and can parallel with each other and with Group C's main.tf work
- **Group D (scripts)**: US4, US7, US10, US11, US14 — different sections of bootstrap.sh and rockport.sh

---

## Parallel Example: Terraform Changes

```bash
# T011 and T023 both modify main.tf — run sequentially:
Task: "T011 [US2] Scope Bedrock IAM in terraform/main.tf"
Task: "T023 [US6] Split SSM PutParameter in terraform/main.tf"  # After T011 (same file)

# These can run in parallel with each other and with the main.tf tasks:
Task: "T033 [US12] Create terraform/cloudtrail.tf"
Task: "T037 [US13] Scope SSM documents in terraform/deployer-policies/iam-ssm.json"
```

## Parallel Example: Script Changes

```bash
# These can all run as parallel tasks (different files or sections):
Task: "T017 [US4] Add cloudflared checksum in scripts/bootstrap.sh"
Task: "T030 [US10] Secure log permissions in scripts/bootstrap.sh"  # Same file — different section, can merge
Task: "T038 [US14] Add DenyNonSSL in scripts/rockport.sh"
```

---

## Implementation Strategy

### MVP First (User Stories 1-3 — All P1)

1. Complete Phase 1: Setup (read-only)
2. Complete Phase 2: Foundational (DB schema changes)
3. Complete Phase 3: US1 — CRIT-1 race condition fix
4. Complete Phase 4: US2 — IAM model scoping
5. Complete Phase 5: US3 — Body size limits
6. **STOP and VALIDATE**: All critical/high severity issues are fixed
7. Deploy and verify with smoke tests

### Incremental Delivery

1. Phases 1-5 → All P1 fixes deployed (Critical + High severity)
2. Phases 6-10 → All P2 fixes deployed (High + Medium severity)
3. Phases 11-16 → All P3 fixes deployed (Low severity + hygiene)
4. Phase 17 → Final polish and documentation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently testable per its acceptance scenarios in spec.md
- Commit after each phase for clean git history and easy rollback
- US1 (CRIT-1) is the highest priority — deploy this fix as soon as possible
- Terraform changes (US2, US6, US12, US13) should be applied together in a single `terraform apply` to minimize plan/apply cycles
