# Tasks: Fix Image-to-Video Support

**Input**: Design documents from `/specs/005-fix-image-to-video/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Not requested. No test tasks included.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Add the shared helper function that all user stories depend on

- [x] T001 Add `parse_image_data_uri()` helper function to extract format string and raw base64 bytes from a data URI in `sidecar/video_api.py` — must handle `data:image/png;base64,...` and `data:image/jpeg;base64,...`, normalize `jpg` to `jpeg`, and return a tuple of `(format, raw_base64)`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Fix image validation that all image-to-video paths depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 [US3] Add alpha/transparency handling to `validate_image()` in `sidecar/video_api.py` and change its return type from `None` to `(bytes, str)` (raw image bytes and format string). After opening the image with Pillow, check `img.mode in ("RGBA", "LA", "PA")`: if alpha channel present, get alpha via `img.getchannel("A")` and check `alpha.getextrema()`; if min alpha == 255 (all pixels fully opaque), strip alpha with `img.convert("RGB")` and re-encode to get clean bytes; if min alpha < 255 (actual transparency), reject with error: "Image contains transparent pixels (got {mode} mode with alpha < 255). Nova Reel requires fully opaque images." Return the (potentially re-encoded) raw bytes and format string so `parse_image_data_uri()` (T001) can pass them to Bedrock.

**Coverage notes**:
- FR-006 (accept PNG/JPEG 1280x720): Pre-satisfied by existing `validate_image()` — no task needed
- FR-007 (no text-only regression): Verified at each phase checkpoint — no dedicated task needed
- US3 (Image Validation & Error Handling): Covered by T001 (parse helper validates data URI format) + T002 (alpha handling: strip if opaque, reject if transparent) + existing `validate_image()` (dimensions, format, size). Note: T002 changes `validate_image` to potentially re-encode the image (alpha stripping), so callers that need the raw bytes should use the data returned by `parse_image_data_uri()` which calls `validate_image` internally

**Checkpoint**: Foundation ready — shared helper and validation in place

---

## Phase 3: User Story 1 - Single-Shot Image Animation (Priority: P1) MVP

**Goal**: Single-shot image-to-video requests send the correct Bedrock `TEXT_VIDEO` payload with `textToVideoParams.images` array

**Independent Test**: `curl -X POST /v1/videos/generations` with `prompt` + `image` data URI → job created, Bedrock receives correct payload, video completes

### Implementation for User Story 1

- [x] T003 [US1] Add duration enforcement for single-shot + image in `create_video()` in `sidecar/video_api.py` — in the `else` (single_shot) branch, after `if req.image: validate_image(req.image)`, add check: if `req.image` and `duration != 6`, return 400 with message "Single-shot with image is fixed at 6 seconds. Remove 'duration' or set it to 6."
- [x] T004 [US1] Fix single-shot Bedrock request body in `create_video()` in `sidecar/video_api.py` — replace `text_params["image"] = req.image` (line ~290) with: call `parse_image_data_uri(req.image)` to get `(fmt, raw_b64)`, then set `text_params["images"] = [{"format": fmt, "source": {"bytes": raw_b64}}]`

**Checkpoint**: Single-shot image-to-video should produce valid Bedrock payloads. Text-only single-shot must still work (no regression).

---

## Phase 4: User Story 2 - Multi-Shot Image Animation (Priority: P2)

**Goal**: Multi-shot requests use `MULTI_SHOT_MANUAL` taskType with correct `multiShotManualParams.shots` structure and per-shot image formatting

**Independent Test**: `curl -X POST /v1/videos/generations` with `shots` array (some with images) → job created with `MULTI_SHOT_MANUAL` taskType

### Implementation for User Story 2

- [x] T005 [US2] Fix multi-shot Bedrock request body in `create_video()` in `sidecar/video_api.py` — replace the entire `if mode == "multi_shot"` block (lines ~271-286): change taskType from `TEXT_VIDEO` to `MULTI_SHOT_MANUAL`, change top-level key from `textToVideoParams` to `multiShotManualParams`, change inner key from `videos` to `shots`, for each shot with an image call `parse_image_data_uri(shot.image)` and set `v["image"] = {"format": fmt, "source": {"bytes": raw_b64}}` (not `imageDataURI`), remove `durationSeconds` from `videoGenerationConfig` (derived from shot count)

**Checkpoint**: Multi-shot with and without images should produce valid Bedrock payloads. Text-only multi-shot must still work.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Documentation updates

- [x] T006 Update image-to-video notes in `CLAUDE.md` — add bullet points documenting: single-shot image-to-video is 6s fixed duration, multi-shot uses `MULTI_SHOT_MANUAL` taskType, images must be 1280x720 PNG/JPEG with no transparent pixels (opaque alpha channels are automatically stripped), submitted as data URIs

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Can run in parallel with Phase 1 (different function)
- **User Story 1 (Phase 3)**: Depends on T001 (parse helper) completion
- **User Story 2 (Phase 4)**: Depends on T001 (parse helper) completion; independent of US1
- **Polish (Phase 5)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Depends on T001 only — independent of US2
- **User Story 2 (P2)**: Depends on T001 only — independent of US1
- **User Story 3 (P2)**: Validation covered by T001 + T002 (foundational) + existing `validate_image()` — complete before US1/US2 start

### Parallel Opportunities

- T001 and T002 can be written in parallel (different functions in same file, no overlap). Note: T001's `parse_image_data_uri()` calls T002's modified `validate_image()`, so both must be complete before US1/US2 start
- T003 and T004 are sequential (both modify the single-shot branch)
- US1 (T003-T004) and US2 (T005) can run in parallel after T001 completes (different code blocks)

---

## Parallel Example: Setup + Foundational

```bash
# These modify different functions and can run in parallel:
Task: "Add parse_image_data_uri() helper in sidecar/video_api.py"
Task: "Add alpha/transparency check to validate_image() in sidecar/video_api.py"
```

## Parallel Example: User Stories

```bash
# After T001 completes, US1 and US2 can proceed in parallel:
Task: "Fix single-shot Bedrock payload in create_video() — images array"
Task: "Fix multi-shot Bedrock payload in create_video() — MULTI_SHOT_MANUAL"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001 — parse helper)
2. Complete Phase 2: Foundational (T002 — transparency check)
3. Complete Phase 3: User Story 1 (T003-T004 — single-shot fix)
4. **STOP and VALIDATE**: Deploy and test single-shot image-to-video with curl
5. If working → MVP delivered

### Incremental Delivery

1. T001 + T002 → Foundation ready
2. T003 + T004 → Single-shot image-to-video works (MVP)
3. T005 → Multi-shot image-to-video works
4. T006 → Documentation updated

---

## Notes

- All changes are in a single file: `sidecar/video_api.py` (except T006 in `CLAUDE.md`)
- No database schema changes needed
- No new dependencies needed (Pillow already imported)
- Text-only video generation must not regress — verify after each phase
- Deploy with `./scripts/rockport.sh config push` after all changes
