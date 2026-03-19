# Tasks: Complete Image Services

**Input**: Design documents from `/specs/009-complete-image-services/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: Add cost entries and constants for all new models

- [ ] T001 Add new model cost entries to STABILITY_COSTS dict in sidecar/image_api.py: stability-inpaint ($0.04), stability-erase ($0.04), stability-creative-upscale ($0.06), stability-fast-upscale ($0.04), stability-search-recolor ($0.04), stability-outpaint ($0.04)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: No foundational changes needed — all infrastructure (WAF, tunnel, IAM, auth helpers, Bedrock clients) is already in place.

**Checkpoint**: No blocking work — user story implementation can begin immediately after T001.

---

## Phase 3: User Story 1 - Inpainting and Erasing (Priority: P1) 🎯 MVP

**Goal**: Users can mask regions of images and either replace them (inpaint) or remove them (erase).

**Independent Test**: POST to `/v1/images/inpaint` with image + mask + prompt; POST to `/v1/images/erase` with image + mask. Both return edited images.

### Implementation for User Story 1

- [ ] T002 [P] [US1] Add InpaintRequest Pydantic model in sidecar/image_api.py: image (str, required), prompt (str, 0-10000), mask (str|None), grow_mask (int, 0-20, default 5), negative_prompt (str|None, 10000), seed (int|None, 0-4294967294), output_format (str, default png), style_preset (str|None)
- [ ] T003 [P] [US1] Add EraseRequest Pydantic model in sidecar/image_api.py: image (str, required), mask (str|None), grow_mask (int, 0-20, default 5), seed (int|None, 0-4294967294), output_format (str, default png)
- [ ] T004 [US1] Implement POST /v1/images/inpaint endpoint in sidecar/image_api.py: authenticate, check budget, validate image + optional mask via _validate_stability_image, build payload with _build_stability_payload (pass mask and grow_mask as extra params), invoke us.stability.stable-image-inpaint-v1:0 via invoke_stability_model(bedrock_us_west_2, ...), log spend as stability-inpaint, return _make_image_response
- [ ] T005 [US1] Implement POST /v1/images/erase endpoint in sidecar/image_api.py: authenticate, check budget, validate image + optional mask, build payload manually (image, mask, grow_mask, seed, output_format — NO prompt/negative_prompt/style_preset), invoke us.stability.stable-image-erase-object-v1:0, log spend as stability-erase, return _make_image_response
- [ ] T006 [US1] Add smoke tests for inpaint and erase in tests/smoke-test.sh: POST with invalid image data to /v1/images/inpaint and /v1/images/erase, verify 400/422 response (confirms routing without API cost)

**Checkpoint**: Inpaint and erase endpoints functional and independently testable.

---

## Phase 4: User Story 2 - Upscale at Different Quality Tiers (Priority: P1)

**Goal**: Users can upscale images via creative upscale (prompt-guided, up to 4K) or fast upscale (deterministic 4x).

**Independent Test**: POST small image to `/v1/images/creative-upscale` with prompt; POST to `/v1/images/fast-upscale`. Both return larger images.

### Implementation for User Story 2

- [ ] T007 [P] [US2] Add CreativeUpscaleRequest Pydantic model in sidecar/image_api.py: image (str, required), prompt (str, 0-10000), creativity (float, 0.1-0.5, default 0.3), negative_prompt (str|None, 10000), seed (int|None, 0-4294967294), output_format (str, default png), style_preset (str|None)
- [ ] T008 [P] [US2] Add FastUpscaleRequest Pydantic model in sidecar/image_api.py: image (str, required), output_format (str, default png)
- [ ] T009 [US2] Implement POST /v1/images/creative-upscale endpoint in sidecar/image_api.py: authenticate, check budget, validate image with custom max_pixels=1048576 (1MP limit), build payload via _build_stability_payload (pass creativity as extra param), invoke us.stability.stable-creative-upscale-v1:0, log spend as stability-creative-upscale
- [ ] T010 [US2] Implement POST /v1/images/fast-upscale endpoint in sidecar/image_api.py: authenticate, check budget, validate image with custom constraints (32-1536px per side, 1024-1048576 total pixels), build payload manually (only image + output_format), invoke us.stability.stable-fast-upscale-v1:0, log spend as stability-fast-upscale
- [ ] T011 [US2] Add smoke tests for creative-upscale and fast-upscale in tests/smoke-test.sh

**Checkpoint**: Both upscale endpoints functional.

---

## Phase 5: User Story 3 - Search & Recolor (Priority: P2)

**Goal**: Users can find objects in images by description and change their colour.

**Independent Test**: POST image with select_prompt and prompt to `/v1/images/search-recolor`, verify colour change.

### Implementation for User Story 3

- [ ] T012 [US3] Add SearchRecolorRequest Pydantic model in sidecar/image_api.py: image (str, required), prompt (str, 1-10000), select_prompt (str, 1-10000), negative_prompt (str|None, 10000), grow_mask (int, 0-20, default 5), seed (int|None, 0-4294967294), output_format (str, default png), style_preset (str|None)
- [ ] T013 [US3] Implement POST /v1/images/search-recolor endpoint in sidecar/image_api.py: authenticate, check budget, validate image, build payload via _build_stability_payload (pass select_prompt and grow_mask as extra params), invoke us.stability.stable-image-search-recolor-v1:0, log spend as stability-search-recolor
- [ ] T014 [US3] Add smoke test for search-recolor in tests/smoke-test.sh

**Checkpoint**: Search & recolor functional.

---

## Phase 6: User Story 4 - Stability Outpaint (Priority: P2)

**Goal**: Users can extend images directionally (left/right/up/down pixels).

**Independent Test**: POST image with `right: 200` to `/v1/images/stability-outpaint`, verify extended image.

### Implementation for User Story 4

- [ ] T015 [US4] Add StabilityOutpaintRequest Pydantic model in sidecar/image_api.py: image (str, required), left (int, 0-2000, default 0), right (int, 0-2000, default 0), up (int, 0-2000, default 0), down (int, 0-2000, default 0), prompt (str|None, 10000), creativity (float, 0.1-1.0, default 0.5), seed (int|None, 0-4294967294), output_format (str, default png), style_preset (str|None). Add model validator: at least one of left/right/up/down must be > 0
- [ ] T016 [US4] Implement POST /v1/images/stability-outpaint endpoint in sidecar/image_api.py: authenticate, check budget, validate image, build payload manually (image, left, right, up, down, prompt, creativity, seed, output_format, style_preset — NO negative_prompt), invoke us.stability.stable-outpaint-v1:0, log spend as stability-outpaint
- [ ] T017 [US4] Add smoke test for stability-outpaint in tests/smoke-test.sh

**Checkpoint**: Stability outpaint functional alongside existing Nova Canvas outpaint.

---

## Phase 7: User Story 5 - New Base Models Ultra & Core (Priority: P2)

**Goal**: Users can generate images via Stable Image Ultra (high quality) and Core (cheap drafts) through standard /v1/images/generations.

**Independent Test**: POST to `/v1/images/generations` with `model: "stable-image-ultra"` or `model: "stable-image-core"` and a prompt.

### Implementation for User Story 5

- [ ] T018 [P] [US5] Add stable-image-ultra model entry in config/litellm-config.yaml: model_name "stable-image-ultra", litellm_params model "bedrock/stability.stable-image-ultra-v1:1", aws_region_name us-west-2, model_info mode image_generation
- [ ] T019 [P] [US5] Add stable-image-core model entry in config/litellm-config.yaml: model_name "stable-image-core", litellm_params model "bedrock/stability.stable-image-core-v1:1", aws_region_name us-west-2, model_info mode image_generation
- [ ] T020 [US5] Add smoke tests for stable-image-ultra and stable-image-core in tests/smoke-test.sh: POST to /v1/images/generations with each model name and minimal prompt, verify non-error response code

**Checkpoint**: Ultra and Core accessible through standard image generation endpoint.

---

## Phase 8: User Story 6 - Nova Canvas Style Presets (Priority: P3)

**Goal**: Users can apply built-in style presets to Nova Canvas text-to-image generation.

**Independent Test**: POST to `/v1/images/generations` with Nova Canvas model and `style` parameter.

### Implementation for User Story 6

- [ ] T021 [US6] Document Nova Canvas style preset pass-through in README.md: list 8 valid preset values (3D_ANIMATED_FAMILY_FILM, DESIGN_SKETCH, FLAT_VECTOR_ILLUSTRATION, GRAPHIC_NOVEL_ILLUSTRATION, MAXIMALISM, MIDCENTURY_RETRO, PHOTOREALISM, SOFT_DIGITAL_PAINTING), show example request body with textToImageParams.style field
- [ ] T022 [US6] Add smoke test for Nova Canvas style preset pass-through in tests/smoke-test.sh: POST to /v1/images/generations with model nova-canvas and textToImageParams.style, verify request is accepted

**Checkpoint**: Style presets documented and verified.

---

## Phase 9: User Story 7 - Automated Multi-Shot Video (Priority: P3)

**Goal**: Users can generate longer Nova Reel videos (12-120s) from a single prompt.

**Independent Test**: POST video generation request with `mode: "multi-shot-automated"` and long prompt.

### Implementation for User Story 7

- [ ] T023 [US7] Add MULTI_SHOT_AUTOMATED mode handling in sidecar/video_api.py: accept mode "multi-shot-automated" in video generation request, validate prompt length (up to 4000 chars), build Bedrock request with taskType "MULTI_SHOT_AUTOMATED" and multiShotAutomatedParams containing text field, use same async invoke pattern as existing multi-shot manual
- [ ] T024 [US7] Add duration parameter for automated multi-shot in sidecar/video_api.py: accept duration_seconds (12-120) for MULTI_SHOT_AUTOMATED mode, pass to durationSeconds in Bedrock request
- [ ] T025 [US7] Add smoke test for automated multi-shot in tests/smoke-test.sh: POST video generation request with mode "multi-shot-automated" and invalid/short prompt, verify 400/422 response

**Checkpoint**: Automated multi-shot video generation functional.

---

## Phase 10: User Story 8 - Complete Parameter Coverage on Existing Endpoints (Priority: P2)

**Goal**: Existing endpoints expose the full parameter set supported by their Bedrock models.

**Independent Test**: Call existing endpoints with previously missing parameters (aspect_ratio, negative_text) and verify acceptance.

### Implementation for User Story 8

- [ ] T026 [P] [US8] Add aspect_ratio field to StructureRequest in sidecar/image_api.py: optional str, validated against STABILITY_ASPECT_RATIOS, passed as extra_param to _build_stability_payload
- [ ] T027 [P] [US8] Add aspect_ratio field to SketchRequest in sidecar/image_api.py: same pattern as Structure
- [ ] T028 [P] [US8] Add aspect_ratio field to SearchReplaceRequest in sidecar/image_api.py: same pattern as Structure
- [ ] T029 [P] [US8] Add negative_text field to ImageVariationRequest in sidecar/image_api.py: optional str, max_length=1024, pass as negativeText in imageVariationParams Bedrock payload
- [ ] T030 [US8] Fix Nova Canvas OutpaintRequest validation in sidecar/image_api.py: add explicit quality validation (must be "standard" or "premium"), add max_length=1024 on mask_prompt field, add optional negative_text field passed as negativeText in outPaintingParams

**Checkpoint**: All existing endpoints expose full Bedrock API parameter surface.

---

## Phase 11: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, CLAUDE.md updates, final verification

- [ ] T031 Update CLAUDE.md with new endpoint documentation: list all new endpoints, model IDs, parameters, and costs
- [ ] T032 Update README.md with new Stability AI endpoint examples and model documentation
- [ ] T033 Run full smoke test suite (tests/smoke-test.sh) and verify all new tests pass
- [ ] T034 Deploy to live instance via `rockport.sh deploy` or `config push` and verify endpoints work end-to-end

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — T001 first
- **User Stories (Phases 3-10)**: All depend only on T001 (cost entries)
- **Polish (Phase 11)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (Inpaint/Erase)**: Independent — start after T001
- **US2 (Upscale)**: Independent — start after T001
- **US3 (Search & Recolor)**: Independent — start after T001
- **US4 (Stability Outpaint)**: Independent — start after T001
- **US5 (Ultra/Core)**: Independent — start after T001 (different file: litellm-config.yaml)
- **US6 (Style Presets)**: Independent — documentation only
- **US7 (Auto Multi-Shot)**: Independent — different file (video_api.py)
- **US8 (Existing Gaps)**: Independent — modifies existing request models

### Parallel Opportunities

All user stories can be implemented in parallel since they modify different sections of the codebase:
- US1 + US2 + US3 + US4: Different endpoint functions in image_api.py (can be parallelized if working on separate sections)
- US5: litellm-config.yaml only
- US6: README.md only
- US7: video_api.py only
- US8: Modifies existing request models (risk of merge conflicts with US1-US4 if parallel)

**Recommended sequential order for solo developer**: US1 → US2 → US3 → US4 → US8 → US5 → US7 → US6

---

## Parallel Example: User Story 1

```bash
# Launch both request models in parallel (different classes, same file):
Task: "Add InpaintRequest Pydantic model in sidecar/image_api.py"
Task: "Add EraseRequest Pydantic model in sidecar/image_api.py"

# Then implement endpoints sequentially (depend on models):
Task: "Implement POST /v1/images/inpaint endpoint"
Task: "Implement POST /v1/images/erase endpoint"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001)
2. Complete Phase 3: Inpaint + Erase (T002-T006)
3. **STOP and VALIDATE**: Test both endpoints independently
4. Deploy and verify

### Incremental Delivery

1. T001 → Foundation ready
2. US1 (Inpaint/Erase) → Test → Deploy (MVP!)
3. US2 (Upscale) → Test → Deploy
4. US3+US4 (Recolor+Outpaint) → Test → Deploy
5. US5 (Ultra/Core config) → Test → Deploy
6. US8 (Existing gaps) → Test → Deploy
7. US7 (Auto multi-shot) → Test → Deploy
8. US6 (Style presets docs) → Deploy
9. Polish → Final deploy

---

## Notes

- All new sidecar endpoints follow the identical pattern as existing Stability AI endpoints
- No new infrastructure (WAF, tunnel, IAM) changes needed
- All 6 new sidecar model IDs use the `us.` cross-region prefix
- Ultra/Core have NO cross-region profile — use base model ID with `bedrock/` prefix in LiteLLM config
- Erase and Fast Upscale are the simplest endpoints (no prompt parameter)
- Stability Outpaint at `/v1/images/stability-outpaint` avoids conflict with Nova Canvas `/v1/images/outpaint`
