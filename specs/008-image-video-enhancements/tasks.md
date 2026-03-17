# Tasks: Image & Video Generation Enhancements

**Input**: Design documents from `/specs/008-image-video-enhancements/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Smoke tests only (bash-based, added in Polish phase). No unit test framework in this project.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Infrastructure changes that enable all user stories — WAF, tunnel routing, IAM

- [x] T001 Add new image endpoint paths to Cloudflare WAF allowlist in terraform/waf.tf (`/v1/images/variations`, `/v1/images/background-removal`, `/v1/images/outpaint`, `/v1/images/structure`, `/v1/images/sketch`, `/v1/images/style-transfer`, `/v1/images/remove-background`, `/v1/images/search-replace`, `/v1/images/upscale`, `/v1/images/style-guide`)
- [x] T002 Add tunnel routing split in terraform/tunnel.tf — route `/v1/images/generations` to port 4000 (LiteLLM) and all other `/v1/images/*` paths to port 4001 (sidecar). The `/v1/images/generations` rule must appear before the catch-all to take precedence
- [x] T003 [P] Verify IAM policy in terraform/main.tf covers Stability AI model IDs (`us.stability.stable-*`) in us-west-2. Add explicit model ARNs if needed

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared sidecar infrastructure that all image endpoints and video enhancements depend on

- [x] T004 Add `--claude-only` key detection to the sidecar auth flow in sidecar/video_api.py — extract model restriction info from the LiteLLM `/key/info` response and expose a helper function `is_claude_only_key(key_info) -> bool` that checks whether the key's `models` list is restricted to Anthropic-only models. This will be used by all new image endpoints to return HTTP 403
- [x] T005 [P] Add image spend logging functions to sidecar/db.py — create `log_image_spend(api_key_hash, model, cost, request_id)` that writes to LiteLLM_SpendLogs and increments LiteLLM_VerificationToken.spend, following the same pattern as existing video spend logging. Image operations are synchronous so no job tracking table is needed
- [x] T006 [P] Create sidecar/image_resize.py — implement `resize_image(image_bytes, mode, pad_color) -> (resized_bytes, metadata)` with five modes: `scale` (default, resize to 1280x720), `crop-center` (scale to cover then center-crop), `crop-top` (scale to cover then top-crop), `crop-bottom` (scale to cover then bottom-crop), `fit` (scale to fit within 1280x720 maintaining aspect ratio, pad with black or white). Return metadata dict with `original_width`, `original_height`, `mode`. Use Pillow. Handle PNG and JPEG input. Preserve format on output
- [x] T007 [P] Create sidecar/prompt_validation.py — implement `validate_nova_reel_prompt(prompt, shot_number=None) -> Optional[error_dict]` with three checks: (1) negation detection using regex word boundary matching for `no`, `not`, `without`, `don't`, `avoid` — must not trigger on "Nottingham", "knotted", "another"; (2) camera keyword positioning — detect `dolly`, `pan`, `tilt`, `track`, `orbit`, `zoom`, `following shot`, `static shot` (case-insensitive) before the last comma or period; (3) minimum length — reject under 50 characters. Return error dict per contracts/video-prompt-validation.md format or None if valid. `shot_number` is 1-indexed, included in error only for multi-shot
- [x] T008 [P] Create sidecar/image_api.py with shared image endpoint infrastructure — import FastAPI router, implement `authenticate_image_request(authorization_header)` that calls LiteLLM `/key/info`, checks for `--claude-only` restriction (return 403), and checks budget (return 402). Implement `parse_data_uri(data_uri) -> (raw_base64, media_type)` helper to strip data URI prefix. Implement `calculate_nova_canvas_cost(n, width, height, quality) -> float` per research.md pricing table. Implement `calculate_stability_cost(model_name) -> float` with per-service cost lookup (estimated $0.04-0.08/image, to be confirmed on first deploy). Implement shared `invoke_stability_model(bedrock_client, model_id, payload) -> dict` helper that calls `invoke_model`, parses the `seeds`/`finish_reasons`/`images` response format, and raises on `finish_reasons` errors. Register the router in video_api.py's FastAPI app

**Checkpoint**: Foundation ready — user story implementation can now begin

---

## Phase 3: User Story 1 — Video Prompt Quality Guardrails (Priority: P1) MVP

**Goal**: Reject Nova Reel prompts with negation words, misplaced camera keywords, or insufficient length before any Bedrock cost is incurred

**Independent Test**: Send malformed prompts to `/v1/videos/generations` with `model: "nova-reel"` and verify HTTP 400 responses with actionable error messages. Verify Luma Ray2 requests with the same prompts are accepted

### Implementation for User Story 1

- [x] T009 [US1] Integrate prompt validation into the video generation request flow in sidecar/video_api.py — call `validate_nova_reel_prompt()` for Nova Reel requests (single-shot: validate `prompt` field; multi-shot: validate each `shots[].prompt` with 1-indexed shot number). Skip validation entirely for Luma Ray2 requests. Return HTTP 400 with the error dict from prompt_validation.py on first failure. Validation must run before any Bedrock call or image processing

**Checkpoint**: User Story 1 complete — Nova Reel prompt validation is active, Ray2 unaffected

---

## Phase 4: User Story 2 — Auto-resize Images for Nova Reel (Priority: P1)

**Goal**: Automatically resize non-1280x720 images instead of rejecting them, with configurable resize modes

**Independent Test**: Submit a 1920x1080 image to `/v1/videos/generations` with `model: "nova-reel"` and verify the video generation proceeds (previously would have been rejected). Check response includes `resize_applied` metadata

### Implementation for User Story 2

- [x] T010 [US2] Add `resize_mode` and `pad_color` fields to the VideoGenerationRequest model in sidecar/video_api.py — `resize_mode: Optional[str]` (default `scale`, valid: `scale`, `crop-center`, `crop-top`, `crop-bottom`, `fit`), `pad_color: Optional[str]` (default `black`, valid: `black`, `white`). Add validation that rejects invalid values with HTTP 400
- [x] T011 [US2] Replace the dimension rejection logic in `validate_image_nova_reel()` in sidecar/video_api.py — instead of rejecting images that aren't 1280x720, call `resize_image()` from image_resize.py. Apply resize before the existing format/opacity/size validation. For multi-shot requests, apply resize independently to each shot image. Store resize metadata for inclusion in the response
- [x] T012 [US2] Add `resize_applied` field to the video generation response in sidecar/video_api.py — for single-shot: `resize_applied: {original_width, original_height, mode}` or `null`. For multi-shot: `resize_applied` is an array (one entry per shot with an image, `null` for shots without images). Include in both the creation response (HTTP 202) and the job status response

**Checkpoint**: User Story 2 complete — images of any dimension are accepted and auto-resized for Nova Reel

---

## Phase 5: User Story 3 — Nova Canvas Image Variation (Priority: P2)

**Goal**: Enable IMAGE_VARIATION via `/v1/images/variations` with similarityStrength control

**Independent Test**: POST to `/v1/images/variations` with a reference image, prompt, and similarity_strength=0.7. Verify base64 image(s) returned

### Implementation for User Story 3

- [x] T013 [US3] Implement POST `/v1/images/variations` endpoint in sidecar/image_api.py — accept request body per contracts/nova-canvas-endpoints.md (images array of data URIs, prompt, similarity_strength, seed, cfg_scale, n, width, height, quality). Validate: images 1-5, PNG/JPEG only, no transparency, max 10MB each; prompt 1-1024 chars; similarity_strength 0.2-1.0; width/height 320-4096 divisible by 16. Build Bedrock payload with `taskType: "IMAGE_VARIATION"`, `imageVariationParams` (raw base64 strings, not format-wrapped), `imageGenerationConfig`. Call `bedrock_us_east_1.invoke_model(modelId="amazon.nova-canvas-v1:0")`. Parse response `images` array. Log spend via `log_image_spend()`. Return `{"images": [{"b64_json": "..."}], "model": "nova-canvas", "cost": X.XX}`

**Checkpoint**: User Story 3 complete — IMAGE_VARIATION accessible through the proxy

---

## Phase 6: User Story 4 — Nova Canvas Background Removal (Priority: P2)

**Goal**: Enable BACKGROUND_REMOVAL via `/v1/images/background-removal` returning PNG with transparency

**Independent Test**: POST to `/v1/images/background-removal` with a character image. Verify returned base64 decodes to a PNG with alpha channel

### Implementation for User Story 4

- [x] T014 [US4] Implement POST `/v1/images/background-removal` endpoint in sidecar/image_api.py — accept request body per contracts/nova-canvas-endpoints.md (image data URI only). Validate: PNG/JPEG, max 10MB. Build Bedrock payload with `taskType: "BACKGROUND_REMOVAL"`, `backgroundRemovalParams: {"image": "<raw-base64>"}`. No `imageGenerationConfig`. Call `bedrock_us_east_1.invoke_model()`. Log spend (always 1 image, standard quality pricing). Return `{"images": [{"b64_json": "..."}], "model": "nova-canvas", "cost": X.XX}`

**Checkpoint**: User Story 4 complete — background removal accessible through the proxy

---

## Phase 7: User Story 5 — Nova Canvas Outpainting (Priority: P2)

**Goal**: Enable OUTPAINTING via `/v1/images/outpaint` with mask_prompt or mask_image

**Independent Test**: POST to `/v1/images/outpaint` with an image, mask_prompt, and text prompt. Verify returned image extends the original

### Implementation for User Story 5

- [x] T015 [US5] Implement POST `/v1/images/outpaint` endpoint in sidecar/image_api.py — accept request body per contracts/nova-canvas-endpoints.md (image, prompt, mask_prompt OR mask_image, outpainting_mode, seed, cfg_scale, n, quality). Validate: exactly one of mask_prompt or mask_image required (reject 400 if neither or both); if mask_image provided, validate same dimensions as input image; prompt 1-1024 chars. Build Bedrock payload with `taskType: "OUTPAINTING"`, `outPaintingParams` (image as raw base64, mask semantics: black=keep, white=edit). Do NOT include width/height in imageGenerationConfig (output matches input dimensions per research.md). Call `bedrock_us_east_1.invoke_model()`. Log spend. Return response

**Checkpoint**: User Story 5 complete — all three Nova Canvas advanced operations accessible

---

## Phase 8: User Stories 6-12 — Stability AI Image Services (Priority: P3)

**Goal**: Enable all seven Stability AI Image Service endpoints through the proxy

**Independent Test**: POST to each of the seven endpoints with valid images and verify responses contain base64 images

### Implementation for User Stories 6-12

- [x] T016 [P] [US6] Implement POST `/v1/images/structure` endpoint in sidecar/image_api.py — accept request per contracts/stability-ai-endpoints.md (image, prompt, control_strength, negative_prompt, seed, output_format, style_preset). Validate: PNG/JPEG/WebP, 64px min, 9.4MP max, control_strength 0-1. Build Bedrock payload for `us.stability.stable-image-control-structure-v1:0` — pass raw base64 in `image` field (strip data URI prefix via `parse_data_uri` from T008). Call `invoke_stability_model()` from T008 shared helpers with `bedrock_us_west_2`. Log spend via `calculate_stability_cost()`. Return `{"images": [{"b64_json": "..."}], "model": "stability-structure", "cost": X.XX}`
- [x] T017 [P] [US7] Implement POST `/v1/images/sketch` endpoint in sidecar/image_api.py — same schema and flow as structure endpoint but use model ID `us.stability.stable-image-control-sketch-v1:0`. Reuse validation and response logic from T016
- [x] T018 [P] [US8] Implement POST `/v1/images/style-transfer` endpoint in sidecar/image_api.py — accept request per contracts/stability-ai-endpoints.md (init_image, style_image, prompt, negative_prompt, seed, output_format, composition_fidelity, style_strength, change_strength). Note: uses `init_image`/`style_image` field names NOT `image`. Validate both images. Use model ID `us.stability.stable-style-transfer-v1:0`. No style_preset parameter for this service
- [x] T019 [P] [US9] Implement POST `/v1/images/remove-background` endpoint in sidecar/image_api.py — accept request (image, output_format only). Use model ID `us.stability.stable-image-remove-background-v1:0`. Simplest endpoint — no prompt, no seed
- [x] T020 [P] [US10] Implement POST `/v1/images/search-replace` endpoint in sidecar/image_api.py — accept request per contracts/stability-ai-endpoints.md (image, prompt, search_prompt, negative_prompt, seed, output_format, grow_mask, style_preset). Validate grow_mask 0-20. Use model ID `us.stability.stable-image-search-replace-v1:0`
- [x] T021 [P] [US11] Implement POST `/v1/images/upscale` endpoint in sidecar/image_api.py — accept request per contracts/stability-ai-endpoints.md (image, prompt, creativity, negative_prompt, seed, output_format). Validate: input max 1MP, creativity 0.1-0.5. Use model ID `us.stability.stable-conservative-upscale-v1:0`. No style_preset
- [x] T022 [P] [US12] Implement POST `/v1/images/style-guide` endpoint in sidecar/image_api.py — accept request per contracts/stability-ai-endpoints.md (image, prompt, aspect_ratio, fidelity, negative_prompt, seed, output_format, style_preset). Validate aspect_ratio from 9 allowed values, fidelity 0-1. Use model ID `us.stability.stable-image-style-guide-v1:0`

**Checkpoint**: All Stability AI Image Services accessible through the proxy

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Smoke tests, documentation, config push updates

- [ ] T023 Add regression smoke test to tests/smoke-test.sh — verify `/v1/images/generations` (LiteLLM on port 4000) still works after tunnel routing split by sending a basic nova-canvas text-to-image request (expect 200 with b64_json). This confirms the `/v1/images/generations` → port 4000 route takes precedence over the `/v1/images/*` → port 4001 catch-all
- [ ] T024 Add smoke tests for prompt validation to tests/smoke-test.sh — test negation rejection (expect 400), camera keyword rejection (expect 400), min-length rejection (expect 400), clean prompt acceptance (expect 202), Ray2 bypass (expect 202)
- [ ] T025 [P] Add smoke tests for auto-resize to tests/smoke-test.sh — test submitting a non-1280x720 image with nova-reel (expect 202 with resize_applied metadata)
- [ ] T026 [P] Add smoke tests for Nova Canvas endpoints to tests/smoke-test.sh — test `/v1/images/variations` (expect 200 with b64_json), `/v1/images/background-removal` (expect 200), `/v1/images/outpaint` (expect 200). Test `--claude-only` key rejection (expect 403)
- [ ] T027 [P] Add smoke tests for Stability AI endpoints to tests/smoke-test.sh — test at least `/v1/images/structure` and `/v1/images/remove-background` (expect 200). Test `--claude-only` key rejection (expect 403)
- [ ] T028 Update CLAUDE.md with new endpoint documentation — add image endpoint descriptions, Stability AI model IDs, resize_mode parameter, prompt validation rules to the Important Notes section
- [x] T029 [P] Update scripts/rockport.sh config push to include new sidecar files (image_api.py, prompt_validation.py, image_resize.py) if not already covered by the existing push pattern
- [x] T030 [P] Create docs/future-ideas.md with deferred features — Pipeline orchestration endpoint (Canvas-to-Reel in one call), Nova Lite prompt rewriting as opt-in middleware
- [ ] T031 Run quickstart.md validation — execute each curl example from specs/008-image-video-enhancements/quickstart.md against a deployed instance and verify expected responses

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion — BLOCKS all user stories
- **User Stories (Phase 3-8)**: All depend on Foundational phase completion
  - US1 (prompt validation) and US2 (auto-resize) are independent of each other
  - US3-5 (Nova Canvas endpoints) depend on T008 (shared image_api.py infra, created in Phase 2)
  - US6-12 (Stability AI) depend on T008 (shared infra) but are independent of US3-5
- **Polish (Phase 9)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (P1)**: Phase 2 only → fully independent
- **US2 (P1)**: Phase 2 only → fully independent
- **US3 (P2)**: Phase 2 only → fully independent (shared infra now in T008)
- **US4 (P2)**: Phase 2 only → fully independent
- **US5 (P2)**: Phase 2 only → fully independent
- **US6-12 (P3)**: Phase 2 only → all seven are independent of each other ([P] marked)

### Within Each User Story

- Core implementation before integration
- Story complete before moving to next priority

### Parallel Opportunities

- T001, T002, T003 can run in parallel (different Terraform files)
- T004, T005, T006, T007, T008 can run in parallel (different Python files)
- US1 and US2 can run in parallel after Phase 2
- US3, US4, and US5 can run in parallel after Phase 2
- All seven Stability AI endpoints (T016-T022) can run in parallel after Phase 2

---

## Parallel Example: Phase 2

```bash
# Launch all foundational tasks together (different files):
Task: "Add claude-only key detection in sidecar/video_api.py"
Task: "Add image spend logging in sidecar/db.py"
Task: "Create sidecar/image_resize.py"
Task: "Create sidecar/prompt_validation.py"
Task: "Create sidecar/image_api.py with shared infra"
```

## Parallel Example: Stability AI Endpoints

```bash
# Launch all seven endpoints together (same file but independent functions):
Task: "Implement /v1/images/structure in sidecar/image_api.py"
Task: "Implement /v1/images/sketch in sidecar/image_api.py"
Task: "Implement /v1/images/style-transfer in sidecar/image_api.py"
Task: "Implement /v1/images/remove-background in sidecar/image_api.py"
Task: "Implement /v1/images/search-replace in sidecar/image_api.py"
Task: "Implement /v1/images/upscale in sidecar/image_api.py"
Task: "Implement /v1/images/style-guide in sidecar/image_api.py"
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2 Only)

1. Complete Phase 1: Setup (Terraform changes)
2. Complete Phase 2: Foundational (shared modules)
3. Complete Phase 3: US1 — Prompt validation
4. Complete Phase 4: US2 — Auto-resize
5. **STOP and VALIDATE**: Deploy, run smoke tests, verify existing video generation still works
6. These two stories improve the existing video workflow with zero new endpoints

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. US1 + US2 → Deploy (video workflow improved, no new endpoints yet)
3. US3 (IMAGE_VARIATION) → Deploy (most valuable new endpoint for animation pipeline)
4. US4 + US5 → Deploy (complete Nova Canvas coverage)
5. US6-12 → Deploy (full Stability AI suite)
6. Polish → Final smoke tests, docs, future ideas

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- All Stability AI endpoints share the same response format and auth pattern — T016 establishes the pattern, T017-T022 replicate it
- Stability AI endpoints are marked [P] because they're independent functions, even though they're in the same file (image_api.py) — each is a self-contained endpoint handler
- The sidecar's existing `bedrock_us_east_1` and `bedrock_us_west_2` boto3 clients are reused for Nova Canvas and Stability AI respectively
- No new Python dependencies required — all imports (FastAPI, boto3, Pillow, pydantic, httpx, psycopg2) already exist
