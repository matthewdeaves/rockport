# Tasks: Video Generation Sidecar API

**Input**: Design documents from `/specs/004-video-generation-sidecar/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/video-api.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: Create sidecar project structure and install dependencies

- [x] T001 Create sidecar directory structure: `sidecar/`, `sidecar/tests/`
- [x] T002 Create `sidecar/requirements.txt` with psycopg2-binary dependency
- [x] T003 [P] Create systemd unit file `config/rockport-video.service` for the sidecar (port 4001, 256MB MemoryMax, User=litellm, EnvironmentFile=/etc/litellm/env, Restart=always)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Infrastructure that MUST be complete before any user story can be implemented

- [x] T004 Add S3 bucket resource in `terraform/s3.tf` — bucket name `rockport-video-{account_id}-us-east-1`, us-east-1 provider, SSE-S3 encryption, public access blocked, 7-day lifecycle policy for `jobs/` prefix
- [x] T005 [P] Add IAM policy for async invoke in `terraform/main.tf` — new `aws_iam_role_policy` resource named `bedrock_async_invoke` granting `bedrock:StartAsyncInvoke`, `bedrock:GetAsyncInvoke`, `bedrock:ListAsyncInvokes` on `arn:aws:bedrock:us-east-1::foundation-model/*` (separate resource from existing `bedrock_invoke` policy)
- [x] T006 [P] Add IAM policy for S3 video bucket in `terraform/main.tf` — new `aws_iam_role_policy` resource named `s3_video_bucket` granting `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the video bucket (separate resource from the Bedrock policies)
- [x] T007 [P] Add `/v1/videos` path to WAF allowlist in `terraform/waf.tf` — add `not starts_with(http.request.uri.path, "/v1/videos")` to the expression
- [x] T008 [P] Add `us_east_1` AWS provider alias in `terraform/providers.tf` (or `terraform/s3.tf`) for the S3 bucket resource since it must be in us-east-1
- [x] T009 Create `sidecar/db.py` — PostgreSQL connection pool (psycopg2), `create_tables()` to create `rockport_video_jobs` table if not exists (schema per data-model.md), `insert_job()`, `get_job()`, `list_jobs()`, `update_job_status()`, `count_in_progress_jobs()`, `log_spend()` (insert into LiteLLM_SpendLogs + increment LiteLLM_VerificationToken.spend). Note: the `prompt` column stores plain text for single-shot mode and a JSON array of shot objects for multi-shot mode — document this convention in code comments
- [x] T010 Create `sidecar/video_api.py` — FastAPI app skeleton with health endpoint (`GET /v1/videos/health` — must verify both DB connectivity and Bedrock reachability via a lightweight `list_async_invokes` call with max_results=1), startup event to initialize DB pool and boto3 bedrock-runtime client (us-east-1), auth dependency that calls `http://127.0.0.1:4000/key/info` with master key to validate user's Bearer token
- [x] T011 Update `config/litellm.service` — change MemoryMax from 1536M to 1280M to leave room for the sidecar

**Checkpoint**: Foundation ready — Terraform resources defined, DB layer ready, FastAPI skeleton with auth running

---

## Phase 3: User Story 1 — Generate a Video from a Text Prompt (Priority: P1) MVP

**Goal**: End-to-end text-to-video: submit prompt → poll status → get download URL → spend tracked

**Independent Test**: POST a video generation request with a text prompt, poll until completed, verify presigned URL works and spend appears in `rockport.sh spend`

### Implementation for User Story 1

- [x] T012 [US1] Implement `POST /v1/videos/generations` single-shot endpoint in `sidecar/video_api.py` — validate request (prompt required, duration defaults to 6, must be multiple of 6, range 6-120), call `bedrock.start_async_invoke()` with `amazon.nova-reel-v1:1` model, S3 output URI `s3://{bucket}/jobs/{uuid}/`, insert job row via `db.insert_job()`, return 202 with job ID and status
- [x] T013 [US1] Implement `GET /v1/videos/generations/{id}` status endpoint in `sidecar/video_api.py` — look up job by ID and api_key_hash, if status is `in_progress` ALWAYS re-poll Bedrock via `bedrock.get_async_invoke()` (never rely solely on cached DB status — this ensures restart recovery per SC-007), on completion: update job row, generate presigned S3 URL (1hr expiry), log spend via `db.log_spend()`, return job with URL. On failure: update job with error, no spend. If job not found or wrong key: 404
- [x] T014 [US1] Implement spend logging in `sidecar/db.py` `log_spend()` — insert row into `LiteLLM_SpendLogs` table with api_key, model="nova-reel", spend=duration*0.08, startTime, metadata with video_job_id. Also run `UPDATE "LiteLLM_VerificationToken" SET spend = spend + $cost WHERE token = $hashed_key`
- [x] T015 [US1] Handle expired videos in `GET /v1/videos/generations/{id}` — when job is completed but S3 object no longer exists (HeadObject fails), update status to "expired" and return appropriate message

**Checkpoint**: Single-shot text-to-video works end-to-end with spend tracking

---

## Phase 4: User Story 2 — Budget Enforcement (Priority: P2)

**Goal**: Pre-flight budget check rejects over-budget requests before starting generation

**Independent Test**: Create key with $1 budget, attempt 30-second video ($2.40), verify rejected with clear error showing remaining budget and estimated cost

### Implementation for User Story 2

- [x] T016 [US2] Add budget enforcement to `POST /v1/videos/generations` in `sidecar/video_api.py` — after auth, calculate estimated cost (duration * 0.08), fetch key info from LiteLLM `/key/info` response (includes `spend` and `max_budget`), if max_budget is set and (spend + estimated_cost) > max_budget, return 402 with estimated_cost and remaining_budget in error response

**Checkpoint**: Over-budget requests are rejected before Bedrock is called

---

## Phase 5: User Story 3 — Poll and List Jobs (Priority: P2)

**Goal**: Users can list their recent jobs and poll individual job status, scoped to their API key

**Independent Test**: Create multiple video jobs, verify list returns only jobs for the requesting key, ordered by most recent first

### Implementation for User Story 3

- [x] T017 [US3] Implement `GET /v1/videos/generations` list endpoint in `sidecar/video_api.py` — query `rockport_video_jobs` filtered by api_key_hash, ordered by created_at DESC, support `limit` (default 20, max 100) and `status` query params, return array of job summaries (no presigned URLs in list view)

**Checkpoint**: Job listing works, scoped to requesting key

---

## Phase 6: User Story 5 — Multi-Shot Video Generation (Priority: P2)

**Goal**: Users provide array of per-shot prompts for fine-grained narrative control over longer videos

**Independent Test**: Submit request with 3 shots, verify job accepted with correct duration (18s) and cost ($1.44), poll until complete

### Implementation for User Story 5

- [x] T018 [US5] Add multi-shot request parsing to `POST /v1/videos/generations` in `sidecar/video_api.py` — if `shots` array present: validate 2-20 shots, each prompt 1-512 chars, optional base64 image per shot (validate 1280x720 if present), calculate duration as 6 * len(shots), reject if both `prompt` and `shots` provided
- [x] T019 [US5] Build multi-shot Bedrock request body in `sidecar/video_api.py` — construct `textToVideoParams.videos[]` array with per-shot `text` and optional `imageDataURI`, set `videoGenerationConfig.durationSeconds` to 6 * num_shots

**Checkpoint**: Multi-shot video generation works end-to-end

---

## Phase 7: User Story 4 — Admin Monitors Video Spend (Priority: P3)

**Goal**: Video costs appear in existing `rockport.sh spend` and `rockport.sh monitor` commands

**Independent Test**: Generate a video, run `rockport.sh spend` and `rockport.sh spend keys`, verify video cost appears in totals

### Implementation for User Story 4

- [x] T020 [US4] Verify spend integration works with no CLI changes — since `log_spend()` writes to `LiteLLM_SpendLogs` and increments `LiteLLM_VerificationToken.spend`, the existing `rockport.sh spend` and `rockport.sh monitor` commands should already show video costs. Test and document any issues.
- [x] T021 [US4] Update `rockport.sh` `cmd_status` to include sidecar health check — call `GET /v1/videos/health` via the tunnel URL alongside existing LiteLLM health check

**Checkpoint**: Admin sees unified spend reports including video costs

---

## Phase 8: User Story 6 — Image-to-Video Generation (Priority: P3)

**Goal**: Users provide a reference image alongside a text prompt for single-shot image-to-video

**Independent Test**: Submit request with base64 1280x720 image and text prompt, verify video generated

### Implementation for User Story 6

- [x] T022 [US6] Add image validation to single-shot mode in `sidecar/video_api.py` — if `image` field present, validate base64 data URI, decode and check dimensions are 1280x720, check format is PNG or JPEG, return 400 with clear error if invalid
- [x] T023 [US6] Pass image to Bedrock in single-shot mode in `sidecar/video_api.py` — include `textToVideoParams.image` (or appropriate Bedrock parameter) with the base64 image data

**Checkpoint**: Image-to-video works for single-shot mode

---

## Phase 9: User Story 2b — Concurrent Job Limits (Priority: P2)

**Goal**: Per-key configurable limit on concurrent in-progress video jobs (default 3)

**Independent Test**: Submit 4 video jobs rapidly with same key, verify 4th is rejected with 429 error showing count and limit

### Implementation for User Story 2b

- [x] T024 [US2] Add concurrent job limit check to `POST /v1/videos/generations` in `sidecar/video_api.py` — before calling Bedrock, count in-progress jobs for this api_key_hash via `db.count_in_progress_jobs()`, compare against limit (default 3, configurable via env var `VIDEO_MAX_CONCURRENT_JOBS`), return 429 with count and limit if exceeded
- [x] T025 [US2] Verify `count_in_progress_jobs(api_key_hash)` in `sidecar/db.py` works correctly — function created in T009, ensure it runs `SELECT COUNT(*) FROM rockport_video_jobs WHERE api_key_hash = $1 AND status = 'in_progress'` and is called by T024's concurrent limit check

**Checkpoint**: Concurrent job limits enforced per key

---

## Phase 10: Deployment Integration

**Purpose**: Bootstrap script, config push, and smoke tests

- [x] T026 Document Cloudflare Tunnel path routing configuration — add instructions to `quickstart.md` and `CLAUDE.md` for configuring the Cloudflare Tunnel to route `/v1/videos/*` requests to `http://localhost:4001` while keeping the default catch-all routing to `http://localhost:4000` (LiteLLM). This is a manual step in the Cloudflare Zero Trust dashboard under Networks > Tunnels > Public Hostname.
- [x] T027 Update `scripts/bootstrap.sh` — add section to: install psycopg2-binary via pip3.11, copy `sidecar/` to `/opt/rockport-video/`, install `rockport-video.service`, create `rockport_video_jobs` table in litellm database, enable and start the sidecar service
- [x] T028 Update `scripts/rockport.sh` `cmd_config_push` — after restarting LiteLLM, also restart the rockport-video sidecar service via SSM
- [x] T029 [P] Update `scripts/rockport.sh` `cmd_upgrade` — also restart rockport-video service
- [x] T030 [P] Add Terraform variable for video bucket name in `terraform/variables.tf`
- [x] T031 [P] Add Terraform output for video bucket name
- [x] T032 Update `scripts/bootstrap.sh` templatefile inputs in `terraform/main.tf` — pass video bucket name and any new variables needed by the sidecar env file

---

## Phase 11: Polish & Cross-Cutting Concerns

- [x] T033 Add video generation smoke tests to `tests/smoke-test.sh` — test POST /v1/videos/generations returns 202, test GET /v1/videos/generations/{id} returns status, test GET /v1/videos/generations list returns array, test invalid key returns 401, test WAF blocks non-allowlisted video paths, test GET /v1/videos/health returns 200
- [x] T034 Update `CLAUDE.md` with video generation notes — document sidecar architecture, Nova Reel constraints (us-east-1 only, 1280x720, 6-120s), pricing, video-specific endpoints, and the Cloudflare Tunnel path routing configuration
- [x] T035 [P] Add `.checkov.yaml` skip entries if needed for new S3 bucket (lifecycle policy, versioning)
- [x] T036 Validate quickstart.md scenarios work end-to-end against deployed instance

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — BLOCKS all user stories
- **Phases 3-9 (User Stories)**: All depend on Phase 2 completion
  - Phase 3 (US1 - Text-to-Video): No story dependencies — MVP
  - Phase 4 (US2 - Budget): Depends on Phase 3 (needs working submission flow)
  - Phase 5 (US3 - List Jobs): Can start after Phase 2 (independent of US1)
  - Phase 6 (US5 - Multi-Shot): Depends on Phase 3 (extends submission flow)
  - Phase 7 (US4 - Admin Spend): Depends on Phase 3 (needs spend data to verify)
  - Phase 8 (US6 - Image-to-Video): Depends on Phase 3 (extends submission flow)
  - Phase 9 (US2b - Concurrent Limits): Depends on Phase 3 (needs working submission flow)
- **Phase 10 (Deployment)**: Depends on Phase 3 minimum (can run after MVP)
- **Phase 11 (Polish)**: Depends on all desired user stories being complete

### Within Each User Story

- Models/DB before services
- Services before endpoints
- Core implementation before edge cases
- Story complete before moving to next priority

### Parallel Opportunities

- T005, T006, T007, T008 can all run in parallel (different Terraform files/resources)
- T003 can run in parallel with Terraform tasks
- Phase 5 (US3 - List Jobs) can run in parallel with Phase 4 (US2 - Budget)
- Phase 7 (US4 - Admin Spend), Phase 8 (US6 - Image-to-Video), Phase 9 (US2b - Concurrent Limits) can run in parallel
- T028, T029 can run in parallel
- T030, T031, T035 can run in parallel

---

## Parallel Example: Phase 2 (Foundational)

```bash
# These Terraform tasks can all run in parallel (different files/resources):
Task T005: "Add IAM policy for async invoke in terraform/main.tf"
Task T006: "Add IAM policy for S3 video bucket in terraform/main.tf"
Task T007: "Add /v1/videos path to WAF allowlist in terraform/waf.tf"
Task T008: "Add us_east_1 AWS provider alias in terraform/providers.tf"
```

## Parallel Example: After Phase 3 (MVP complete)

```bash
# These user story phases can proceed in parallel:
Phase 4 (US2 - Budget Enforcement)
Phase 5 (US3 - List Jobs)
Phase 9 (US2b - Concurrent Limits)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (Terraform + DB + FastAPI skeleton)
3. Complete Phase 3: User Story 1 (text-to-video end-to-end)
4. **STOP and VALIDATE**: Submit a video job, poll until complete, download video, check spend report
5. Complete Phase 10: Deployment integration (bootstrap + config push)
6. Deploy and verify on live instance

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. Add US1 (Text-to-Video) → Test → Deploy (MVP!)
3. Add US2 (Budget) + US2b (Concurrent Limits) → Test → Deploy
4. Add US3 (List Jobs) → Test → Deploy
5. Add US5 (Multi-Shot) → Test → Deploy
6. Add US4 (Admin Spend) + US6 (Image-to-Video) → Test → Deploy
7. Polish → Final deploy

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- The sidecar is ~200 lines of Python across 2 files (video_api.py + db.py)
- Terraform changes are additive (new resources + policy updates), low risk to existing infra
- Cloudflare Tunnel path routing (`/v1/videos/*` → port 4001) is a manual dashboard config step — covered by T026
- psycopg2-binary is the only new pip dependency
