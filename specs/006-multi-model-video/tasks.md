# Tasks: Multi-Model Video Generation

**Input**: Design documents from `/specs/006-multi-model-video/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Terraform infrastructure and database schema changes needed before any sidecar code changes

- [x] T001 Add `aws.us_west_2` provider block to `terraform/s3.tf`
- [x] T002 Add us-west-2 S3 video bucket resources to `terraform/s3.tf` (bucket, encryption, public access block, DenyNonSSL policy, 7-day lifecycle — mirror existing us-east-1 pattern)
- [x] T003 [P] Add us-west-2 async invoke IAM permissions to `terraform/main.tf` (bedrock:InvokeModel, bedrock:StartAsyncInvoke, bedrock:GetAsyncInvoke for us-west-2, S3 access for new bucket)
- [x] T004 Add `VIDEO_BUCKET_US_WEST_2` env var to `config/rockport-video.service` and pass new bucket name from Terraform output
- [x] T005 Add Trivy ignore for us-west-2 S3 bucket SSE-S3 (AVD-AWS-0132) in `.trivyignore`
- [x] T006 Add `model VARCHAR(30) NOT NULL DEFAULT 'nova-reel'` column to `rockport_video_jobs` table via ALTER TABLE in `scripts/bootstrap.sh`

**Checkpoint**: Infrastructure ready — new bucket deployed, IAM updated, DB schema migrated

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Refactor sidecar internals to support multiple models before implementing any model-specific logic

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T007 Define video model registry (dict of model configs with ID, region, constraints, pricing) at top of `sidecar/video_api.py` — replace hardcoded `VIDEO_MODEL_ID` and `COST_PER_SECOND`
- [x] T008 Replace single `bedrock_client` and `s3_client` globals with per-region dicts in `sidecar/video_api.py` lifespan — initialize clients for us-east-1 and us-west-2
- [x] T009 Add `model` field to `VideoGenerationRequest` pydantic model in `sidecar/video_api.py` (optional, default `"nova-reel"`)
- [x] T010 Update `db.insert_job()` in `sidecar/db.py` to accept and store `model` parameter
- [x] T011 Update `db.get_job()`, `db.list_jobs()`, `db.get_job_internals()` in `sidecar/db.py` to return `model` field
- [x] T012 Update `db.log_spend()` in `sidecar/db.py` to use the job's model name instead of hardcoded `"nova-reel"`
- [x] T013 Update `db.COST_PER_SECOND` in `sidecar/db.py` — replace single constant with a function that accepts model and resolution
- [x] T014 Raise `Image.MAX_IMAGE_PIXELS` in `sidecar/video_api.py` to accommodate Ray2's 4096x4096 max (currently set for 1280x720)

**Checkpoint**: Foundation ready — model registry, multi-region clients, and DB layer all support multiple models. No functional changes to API yet.

---

## Phase 3: User Story 1 — Choose a Video Model (Priority: P1) 🎯 MVP

**Goal**: Users can specify `"model": "nova-reel"` or `"model": "luma-ray2"` (or omit for default Nova Reel). Unknown models return 400.

**Independent Test**: Submit requests with `model` field set to `nova-reel`, `luma-ray2`, omitted, and invalid — verify correct routing/rejection.

### Implementation for User Story 1

- [x] T015 [US1] Add model lookup and validation at top of `create_video()` in `sidecar/video_api.py` — resolve model from registry, return 400 with available models list if unknown
- [x] T016 [US1] Pass resolved model config through to Bedrock payload builder and `db.insert_job()` in `sidecar/video_api.py`
- [x] T017 [US1] Select correct `bedrock_client` and `s3_client` based on model's region in `create_video()` and `get_video_status()` in `sidecar/video_api.py`
- [x] T018 [US1] Include `model` field in all API responses (submit 202, poll, list) in `sidecar/video_api.py`
- [x] T019 [US1] Use correct S3 bucket (from env var) based on model region when building `s3_output_uri` in `create_video()` in `sidecar/video_api.py`

**Checkpoint**: Model selection works. Nova Reel requests behave identically to before. `luma-ray2` model is accepted but Ray2-specific validation/payload not yet implemented.

---

## Phase 4: User Story 2 — Ray2 Text-to-Video (Priority: P1)

**Goal**: Users can generate Ray2 videos with aspect ratio, resolution, and duration options.

**Independent Test**: Submit Ray2 text-to-video with `duration: 5`, `aspect_ratio: "9:16"`, `resolution: "720p"` — verify 202 and correct cost estimate.

### Implementation for User Story 2

- [x] T020 [US2] Add `aspect_ratio`, `resolution`, `loop` fields to `VideoGenerationRequest` in `sidecar/video_api.py`
- [x] T021 [US2] Implement Ray2 validation in `create_video()` in `sidecar/video_api.py` — duration must be 5 or 9, validate aspect_ratio and resolution against allowed values, apply defaults (16:9, 720p)
- [x] T022 [US2] Implement Ray2 Bedrock payload builder in `sidecar/video_api.py` — build `modelInput` with `{prompt, aspect_ratio, duration: "5s"/"9s", resolution, loop}` format
- [x] T023 [US2] Implement per-model cost calculation in `create_video()` in `sidecar/video_api.py` — use resolution-dependent pricing for Ray2 ($0.75/s at 540p, $1.50/s at 720p)
- [x] T024 [US2] Reject multi-shot (`shots` param) when model is `luma-ray2` with clear error message in `sidecar/video_api.py`

**Checkpoint**: Ray2 text-to-video works with all aspect ratios, resolutions, and durations. Cost tracking is accurate.

---

## Phase 5: User Story 3 — Ray2 Image-to-Video (Priority: P2)

**Goal**: Users can provide start frame (and optional end frame) images for Ray2 video generation.

**Independent Test**: Submit Ray2 request with `image` data URI — verify 202. Submit with both `image` and `end_image` — verify 202.

### Implementation for User Story 3

- [x] T025 [US3] Add `end_image` field to `VideoGenerationRequest` in `sidecar/video_api.py`
- [x] T026 [US3] Implement Ray2 image validation in `sidecar/video_api.py` — 512x512 to 4096x4096, max 25MB, PNG or JPEG (separate from Nova Reel's exact 1280x720 validation)
- [x] T027 [US3] Build Ray2 `keyframes` payload in `sidecar/video_api.py` — `frame0` from `image`, optional `frame1` from `end_image`, using `{type: "image", source: {type: "base64", media_type, data}}` format
- [x] T028 [US3] Reject `end_image` when model is `nova-reel` with clear error in `sidecar/video_api.py`

**Checkpoint**: Ray2 image-to-video works with start frame and optional end frame. Nova Reel image-to-video unchanged.

---

## Phase 6: User Story 4 — Model-Aware Cost Tracking (Priority: P1)

**Goal**: Budget enforcement and spend tracking use correct per-model pricing.

**Independent Test**: Submit Ray2 720p 5s request with $5 budget key — verify 402 rejection ($7.50 > $5). Submit Nova Reel 6s — verify accepted ($0.48).

### Implementation for User Story 4

- [x] T029 [US4] Update cost calculation in `get_video_status()` in `sidecar/video_api.py` to use model-specific pricing when transitioning jobs to completed
- [x] T030 [US4] Update `db.log_spend()` call in `get_video_status()` in `sidecar/video_api.py` to pass correct model name for spend log entries
- [x] T031 [US4] Verify CLI `spend` and `spend keys` commands correctly reflect Ray2 costs (no CLI code changes expected — spend is read from LiteLLM tables)

**Checkpoint**: Budget enforcement blocks expensive Ray2 requests correctly. Spend tracking reflects per-model costs.

---

## Phase 7: User Story 5 — Per-Model Health Reporting (Priority: P2)

**Goal**: Health endpoint reports status for each video model independently.

**Independent Test**: Call `/v1/videos/health` — verify response includes per-model status for both Nova Reel and Ray2.

### Implementation for User Story 5

- [x] T032 [US5] Refactor `health()` endpoint in `sidecar/video_api.py` to check Bedrock reachability per model (ListAsyncInvokes for each region) and report per-model status
- [x] T033 [US5] Update health response format: replace single `bedrock` field with `models` dict per contract in `sidecar/video_api.py`
- [x] T034 [US5] Update `./scripts/rockport.sh status` to parse new health response format showing per-model status

**Checkpoint**: Health endpoint shows independent status for each model. `rockport.sh status` displays it correctly.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, smoke tests, and cleanup

- [x] T035 [P] Add Ray2 smoke tests to `tests/smoke-test.sh` — model selection test, Ray2 text-to-video submit, Ray2 validation rejection, loop parameter passthrough
- [x] T036 [P] Update README.md video generation section with Ray2 model option, pricing table, and aspect ratio docs
- [x] T037 [P] Update CLAUDE.md with Ray2 notes (model ID, region, pricing, constraints)
- [x] T038 Update Terraform output to include us-west-2 bucket name in `terraform/outputs.tf`
- [x] T039 Run all existing smoke tests to verify backward compatibility (18 tests must pass)
- [x] T040 Run quickstart.md scenarios end-to-end for final validation

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (T006 schema migration)
- **User Story 1 (Phase 3)**: Depends on Phase 2 (model registry, multi-region clients)
- **User Story 2 (Phase 4)**: Depends on Phase 3 (model selection working)
- **User Story 3 (Phase 5)**: Depends on Phase 3 (model selection working); can run in parallel with Phase 4
- **User Story 4 (Phase 6)**: Depends on Phase 4 (Ray2 cost calculation implemented)
- **User Story 5 (Phase 7)**: Depends on Phase 2 (multi-region clients); can run in parallel with Phases 3-6
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (Model Selection)**: Foundation only — MVP
- **US2 (Ray2 Text-to-Video)**: Depends on US1
- **US3 (Ray2 Image-to-Video)**: Depends on US1, parallel with US2
- **US4 (Cost Tracking)**: Depends on US2 (needs Ray2 pricing logic)
- **US5 (Health Reporting)**: Foundation only — parallel with US1-US4

### Parallel Opportunities

Within Phase 1: T002, T003, T005 can run in parallel
Within Phase 2: T010, T011, T012, T013 can run in parallel (different functions in db.py)
Phase 5 (US3) can run in parallel with Phase 4 (US2)
Phase 7 (US5) can run in parallel with Phases 3-6
Phase 8: T035, T036, T037 can run in parallel

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Phase 1: Setup (Terraform + DB migration)
2. Complete Phase 2: Foundational (model registry, multi-region clients)
3. Complete Phase 3: User Story 1 (model selection)
4. Complete Phase 4: User Story 2 (Ray2 text-to-video)
5. **STOP and VALIDATE**: Test Ray2 text-to-video end-to-end
6. Deploy and verify

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. US1 (model selection) → Can select models, Nova Reel still works
3. US2 (Ray2 text-to-video) → Ray2 generates videos with correct pricing
4. US3 (Ray2 image-to-video) → Image input works for Ray2
5. US4 (cost tracking) → Budget enforcement verified
6. US5 (health) → Per-model health reporting
7. Polish → Docs, smoke tests, validation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Commit after each phase completion
- Existing 18 smoke tests must pass at every checkpoint (backward compatibility)
- Ray2 Marketplace subscription must be activated manually before testing
