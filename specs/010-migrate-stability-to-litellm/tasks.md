# Tasks: Migrate Stability AI Image Endpoints to LiteLLM Native

**Input**: Design documents from `/specs/010-migrate-stability-to-litellm/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: No new files or project initialization needed — this is a modification-only feature. Phase 1 is a no-op.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Add the 13 Stability AI image edit models to LiteLLM config and update tunnel routing — these MUST be complete before any cleanup or testing changes.

**CRITICAL**: No user story work can begin until this phase is complete.

- [x] T001 Add 13 Stability AI image edit model entries to config/litellm-config.yaml under a new "Stability AI image edit models" section. Each entry needs: `model_name` (stability-{operation}), `litellm_params.model` (bedrock/stability.{model-id}), `litellm_params.aws_region_name: us-west-2`, and `model_info.mode: image_edit`. Full mapping: stability-structure → stability.stable-image-control-structure-v1:0, stability-sketch → stability.stable-image-control-sketch-v1:0, stability-style-transfer → stability.stable-style-transfer-v1:0, stability-remove-background → stability.stable-image-remove-background-v1:0, stability-search-replace → stability.stable-image-search-replace-v1:0, stability-upscale → stability.stable-conservative-upscale-v1:0, stability-style-guide → stability.stable-image-style-guide-v1:0, stability-inpaint → stability.stable-image-inpaint-v1:0, stability-erase → stability.stable-image-erase-object-v1:0, stability-creative-upscale → stability.stable-creative-upscale-v1:0, stability-fast-upscale → stability.stable-fast-upscale-v1:0, stability-search-recolor → stability.stable-image-search-recolor-v1:0, stability-outpaint → stability.stable-outpaint-v1:0

- [x] T002 Update Cloudflare Tunnel ingress rules in terraform/tunnel.tf. Add a new rule BEFORE the `/v1/images/*` catch-all: `{ hostname = var.domain, path = "/v1/images/edits*", service = "http://localhost:4000" }`. This ensures `/v1/images/edits` routes to LiteLLM (port 4000) while the remaining `/v1/images/*` catch-all still routes Nova Canvas endpoints (variations, background-removal, outpaint) to the sidecar (port 4001). The final ingress order must be: (1) /v1/videos* → :4001, (2) /v1/images/generations* → :4000, (3) /v1/images/edits* → :4000 (NEW), (4) /v1/images/* → :4001, (5) default → :4000

**Checkpoint**: LiteLLM config has 13 new image_edit models and tunnel routing is updated. At this point, if deployed, `/v1/images/edits` would route to LiteLLM and the old sidecar endpoints would still work (both paths active during transition).

---

## Phase 3: User Story 1 — Stability AI via LiteLLM Native (Priority: P1) MVP

**Goal**: All 13 Stability AI image operations work through LiteLLM's `/v1/images/edits` endpoint with correct auth, budget enforcement, and spend tracking.

**Independent Test**: Send a multipart form POST to `/v1/images/edits` with `model=stability-remove-background` and an image file. Verify the response contains a processed image and spend is logged.

### Implementation for User Story 1

- [x] T003 [US1] Verify LiteLLM model ID detection works by checking that the 13 model IDs used in T001 match the patterns in LiteLLM's `_is_stability_edit_model()` method. The method checks for exact string matches on the Bedrock model IDs (e.g., `stability.stable-image-control-structure-v1:0`). Confirm none of the IDs use the `us.` cross-region prefix. Document the verification in a comment at the top of the new config section in config/litellm-config.yaml.

- [x] T004 [US1] Verify --claude-only key restriction works for Stability AI models. In scripts/rockport.sh, the CLAUDE_MODELS variable (line 17) lists only Anthropic model names. Keys created with `--claude-only` use this list as their `models` parameter. Since the new `stability-*` model names are not in CLAUDE_MODELS, LiteLLM will naturally block claude-only keys from accessing them. No code change needed — just verify the existing mechanism covers the new models. If rockport.sh has a `setup-claude` command that creates restricted keys, confirm its model list does not accidentally include stability models.

- [x] T004a [US1] Verify LiteLLM's image_edit mode writes spend to the same `LiteLLM_SpendLogs` table used by other operations. Check LiteLLM's image edit handler code path to confirm spend logging is enabled for image_edit requests. This ensures `rockport.sh spend models` will show Stability AI image edit costs alongside chat and image generation costs. Full verification requires a live deployment — document what to check post-deploy in quickstart.md.

**Checkpoint**: User Story 1 complete. All 13 Stability AI operations accessible via `/v1/images/edits` with correct auth, budget, and spend tracking. Old sidecar endpoints still work in parallel (not yet removed).

---

## Phase 4: User Story 2 — Nova Canvas Continues Working (Priority: P1)

**Goal**: The 3 Nova Canvas endpoints (variations, background-removal, outpaint) continue working through the sidecar unchanged after the migration.

**Independent Test**: Send requests to `/v1/images/variations`, `/v1/images/background-removal`, and `/v1/images/outpaint` and verify each returns correct results.

### Implementation for User Story 2

- [x] T005 [US2] Review sidecar/image_api.py to identify which helper functions and imports are shared between Nova Canvas and Stability AI endpoints. Create a list of: (a) helpers used ONLY by Stability AI endpoints (to be removed in Phase 5), (b) helpers used ONLY by Nova Canvas endpoints (to be preserved), (c) helpers used by BOTH (to be preserved). Key shared helpers: `authenticate_image_request()`, `check_budget()`, `parse_data_uri()`, `decode_and_validate_image()`. Key Stability-only helpers: `invoke_stability_model()`, `_build_stability_payload()`, `_validate_stability_image()`, `_validate_output_format()`, and all `STABILITY_*` constants.

- [x] T006 [US2] Verify the 3 Nova Canvas endpoints in sidecar/image_api.py do NOT depend on any Stability-AI-only helpers or constants. Check that the `variations` endpoint (line ~336), `background_removal` endpoint (line ~422), and `outpaint` endpoint (line ~487) only use shared helpers from the list identified in T005. If any Nova Canvas endpoint uses a Stability-only helper, refactor it before removal.

**Checkpoint**: User Story 2 verified. Nova Canvas endpoints have no Stability AI dependencies and will survive the cleanup in Phase 5.

---

## Phase 5: User Story 3 — Sidecar Code and Infrastructure Cleanup (Priority: P2)

**Goal**: Remove all Stability AI code from the sidecar, update infrastructure config, and update all documentation.

**Independent Test**: Verify sidecar/image_api.py contains only Nova Canvas endpoints, WAF rules are correct, tunnel config is correct, and all docs/diagrams are accurate.

### Implementation for User Story 3

- [x] T007 [US3] Remove all 13 Stability AI endpoint functions from sidecar/image_api.py. Remove the `@router.post` decorated functions for: `/v1/images/structure`, `/v1/images/sketch`, `/v1/images/style-transfer`, `/v1/images/remove-background`, `/v1/images/search-replace`, `/v1/images/upscale`, `/v1/images/style-guide`, `/v1/images/inpaint`, `/v1/images/erase`, `/v1/images/creative-upscale`, `/v1/images/fast-upscale`, `/v1/images/search-recolor`, `/v1/images/stability-outpaint`. Also remove all their Pydantic request models (e.g., `StructureRequest`, `SketchRequest`, etc.).

- [x] T008 [US3] Remove Stability-AI-only helper functions and constants from sidecar/image_api.py. Remove: `invoke_stability_model()`, `_build_stability_payload()`, `_validate_stability_image()`, `_validate_output_format()`, `STABILITY_ASPECT_RATIOS`, `STABILITY_STYLE_PRESETS`, `STABILITY_MAX_PIXELS`, `STABILITY_OUTPUT_FORMATS`. Preserve all shared helpers identified in T005. After removal, verify the file still imports correctly and the 3 Nova Canvas endpoints reference only existing functions.

- [x] T009 [US3] Clean up unused imports in sidecar/image_api.py after removing Stability AI code. Check if any imports (e.g., specific pydantic validators, typing imports) are now unused after the Stability AI removal and remove them.

- [x] T010 [US3] Update the module docstring at the top of sidecar/image_api.py. Change the current description that mentions "Stability AI Image Services (Structure, Sketch, Style Transfer, Remove Background, Search and Replace, Upscale, Style Guide)" to only describe Nova Canvas operations: IMAGE_VARIATION, BACKGROUND_REMOVAL, OUTPAINTING. Remove all Stability AI references from comments throughout the file.

- [x] T011 [P] [US3] Update terraform/tunnel.tf comments. The current ingress rules have no inline comments — add a comment on the new `/v1/images/edits*` rule explaining it routes Stability AI image edit operations to LiteLLM. Update the comment on the `/v1/images/*` catch-all to clarify it now only catches Nova Canvas endpoints (variations, background-removal, outpaint).

- [x] T012 [P] [US3] Update terraform/waf.tf comments. Update the header comment block (lines 1-13) to include `/v1/images/edits` in the allowed paths list and note that it routes to LiteLLM for Stability AI operations. No rule expression changes needed — the existing `/v1/images/` prefix already covers it.

- [x] T013 [P] [US3] Update CLAUDE.md — Image service documentation. Update all references to sidecar image operations. Key changes: (a) In Project Structure, update sidecar/image_api.py description to "Image service endpoints (Nova Canvas variations, background-removal, outpaint)" — remove Stability AI mentions. (b) In Important Notes, update the bullet about "Image service endpoints on sidecar (:4001)" to list only the 3 Nova Canvas endpoints and add a new bullet explaining Stability AI operations now use LiteLLM's /v1/images/edits endpoint with `stability-*` model names. (c) Remove or update the bullets listing Stability AI endpoint costs ($0.04, $0.06 per operation) since LiteLLM tracks these natively now. (d) Update the Cloudflare Tunnel routing description to mention the new /v1/images/edits → :4000 rule. (e) Update the "Active Technologies" section if it references Stability AI sidecar operations. (f) Add the 13 new model names to any model listing. (g) Update any references to sidecar MemoryMax or resource usage if the reduced code significantly changes memory profile.

- [x] T014 [P] [US3] Update README.md — Stability AI image documentation. Key changes: (a) Line 16: Update feature list to say Stability AI operations use LiteLLM's /v1/images/edits, not the sidecar. (b) Lines 32, 46: Update Marketplace subscription notes to remove "sidecar services" phrasing — these are now LiteLLM models. (c) Line 242: Remove or reverse the note saying "/v1/images/edits is not supported" — it is now the primary Stability AI endpoint. (d) Lines 246-272: Replace the sidecar endpoint table with a LiteLLM image_edit model table showing the 13 `stability-*` model names, what they do, and their cost. Explain the multipart form request format. (e) Update the "Advanced Image Operations" section header and intro to distinguish between LiteLLM-native Stability AI operations and sidecar-only Nova Canvas operations. (f) Keep the Nova Canvas sidecar endpoint table (variations, background-removal, outpaint) unchanged.

- [x] T015 [P] [US3] Update docs/rockport_architecture_overview.svg. Modify the sidecar box to only show "Nova Canvas + Video" instead of listing Stability AI operations. Add a flow arrow from LiteLLM to Bedrock labeled "Image Edit (Stability AI)" alongside the existing chat/image-gen flows. Ensure the diagram accurately shows: Client → Cloudflare → Tunnel → LiteLLM (:4000) for /v1/images/edits, and Client → Cloudflare → Tunnel → Sidecar (:4001) for /v1/images/variations|background-removal|outpaint.

- [x] T016 [P] [US3] Update docs/rockport_request_dataflow.svg. Update the image request routing section to show the new flow: /v1/images/edits → LiteLLM → Bedrock (Stability AI, us-west-2). Update the sidecar image flow to only show Nova Canvas operations. Remove any Stability AI sidecar routing arrows.

**Checkpoint**: All Stability AI code removed from sidecar. Infrastructure config updated. All documentation and diagrams accurate. Old sidecar paths now return 404.

---

## Phase 6: User Story 4 — Smoke Tests (Priority: P2)

**Goal**: Smoke test suite validates the new architecture — Stability AI via LiteLLM, Nova Canvas via sidecar, old paths return 404.

**Independent Test**: Run `tests/smoke-test.sh` and verify all tests pass.

### Implementation for User Story 4

- [x] T017 [US4] Update test 18 in tests/smoke-test.sh. Currently tests that `/v1/images/edits` returns 404/405 from sidecar. Change to test that `/v1/images/edits` routes to LiteLLM successfully. Send a multipart form request with `model=stability-remove-background` and an invalid image — expect 400 (validation error from LiteLLM/Bedrock, proving the route works) rather than 404. Update test name and expected codes accordingly.

- [x] T018 [US4] Replace smoke tests 22-29 in tests/smoke-test.sh. These currently test sidecar Stability AI endpoints (/v1/images/structure, /v1/images/remove-background, /v1/images/inpaint, /v1/images/erase, /v1/images/creative-upscale, /v1/images/fast-upscale, /v1/images/search-recolor, /v1/images/stability-outpaint). Replace with: (a) A test that sends a request to `/v1/images/edits` with `model=stability-inpaint` to verify LiteLLM accepts the model (expect 400 for bad input, proving route and model recognition). (b) A test that a removed sidecar path (e.g., `/v1/images/structure`) now returns 404. (c) Keep test count similar — can consolidate 8 tests into 2-3 tests. Renumber subsequent tests.

- [x] T019 [US4] Update test 30 in tests/smoke-test.sh. Currently checks model list contains `stable-image-ultra` and `stable-image-core`. Add checks for at least 2-3 of the new `stability-*` model names (e.g., `stability-inpaint`, `stability-upscale`, `stability-structure`) to verify they appear in the `/v1/models` response.

- [x] T020 [US4] Review and update smoke test numbering and section headers in tests/smoke-test.sh. After replacing tests 22-29 and updating test 18, ensure: (a) Test numbers are sequential with no gaps. (b) Section headers/comments accurately describe each test group. (c) The "Image Endpoint Routing" section comment is updated to reflect the new architecture. (d) The "New Image Sidecar Endpoints (009)" section header is removed or renamed since those endpoints are now gone. (e) The final PASS/FAIL count is correct.

**Checkpoint**: Smoke tests pass with the new architecture. CI/CD will catch regressions.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final verification and cleanup across all changes.

- [x] T021 Run `terraform fmt` on terraform/tunnel.tf and terraform/waf.tf to ensure formatting is correct.
- [x] T022 Run `shellcheck tests/smoke-test.sh` to verify no shell scripting issues were introduced.
- [x] T023 Review config/litellm-config.yaml for YAML formatting consistency — ensure the new image_edit section follows the same indentation and comment style as the existing image_generation section.
- [x] T024 Verify the CLAUDE.md "Recent Changes" section is updated to mention the Stability AI migration and the "Active Technologies" section no longer lists Stability AI as a sidecar technology.
- [x] T025 Verify scripts/rockport.sh has no references to Stability AI endpoints or sidecar image paths (FR-012). Run a grep for "stability", "structure", "sketch", "style-transfer", "search-replace", "search-recolor", "inpaint", "erase", "upscale", "outpaint" (excluding the CLAUDE_MODELS list and general terms). Confirm no stale references exist. No code changes expected.
- [x] T026 Run quickstart.md verification steps (from specs/010-migrate-stability-to-litellm/quickstart.md) against the final codebase to validate readiness for deployment.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 2 (Foundational)**: No dependencies — can start immediately
- **Phase 3 (US1 - Stability AI via LiteLLM)**: Depends on Phase 2 (T001, T002)
- **Phase 4 (US2 - Nova Canvas preserved)**: Depends on Phase 2 (T001, T002) — can run in parallel with Phase 3
- **Phase 5 (US3 - Cleanup)**: Depends on Phase 3 AND Phase 4 completion (must verify both paths work before removing old code)
- **Phase 6 (US4 - Smoke tests)**: Depends on Phase 5 (tests must reflect final state)
- **Phase 7 (Polish)**: Depends on all previous phases

### User Story Dependencies

- **US1 (Stability AI via LiteLLM, P1)**: Can start after Phase 2. Independent.
- **US2 (Nova Canvas preserved, P1)**: Can start after Phase 2. Independent of US1. Can run in parallel with US1.
- **US3 (Cleanup, P2)**: Depends on US1 and US2 both being verified working. Cannot start until both are confirmed.
- **US4 (Smoke tests, P2)**: Depends on US3 (tests must reflect final code state).

### Within Each User Story

- T007 before T008 (remove endpoints before helpers — ensures no orphan references)
- T008 before T009 (remove helpers before cleaning imports)
- T007-T009 before T010-T016 (code cleanup before documentation)
- T013-T016 can all run in parallel (different files)

### Parallel Opportunities

- T002 can run in parallel with T001 (different files: tunnel.tf vs litellm-config.yaml)
- T003 and T004 can run in parallel (both are verification, no file changes)
- T005 and T006 can run in parallel with T003 and T004 (all verification tasks)
- T011, T012, T013, T014, T015, T016 can all run in parallel (different files, all marked [P]). T010 is sequential after T009 (same file)
- T017, T018, T019 are sequential (same file: smoke-test.sh)

---

## Parallel Example: Phase 5 (Cleanup)

```text
# Sequential (same file — sidecar/image_api.py):
T007 → T008 → T009 → T010

# Then parallel (different files, after T010):
T011: terraform/tunnel.tf comments
T012: terraform/waf.tf comments
T013: CLAUDE.md updates
T014: README.md updates
T015: docs/rockport_architecture_overview.svg
T016: docs/rockport_request_dataflow.svg
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Phase 2: Add LiteLLM config + tunnel routing (T001-T002)
2. Complete Phase 3: Verify Stability AI works via LiteLLM (T003-T004)
3. Complete Phase 4: Verify Nova Canvas unaffected (T005-T006)
4. **STOP and VALIDATE**: Both paths work — old and new coexist
5. Deploy if needed for validation

### Full Delivery

6. Complete Phase 5: Remove old code, update docs (T007-T016)
7. Complete Phase 6: Update smoke tests (T017-T020)
8. Complete Phase 7: Polish and final validation (T021-T025)
9. Deploy and run smoke tests against live instance

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- This is a code-removal migration — most risk is in accidentally removing shared helpers
- T005 (dependency audit) is the critical gate that prevents breaking Nova Canvas
- The old sidecar endpoints remain functional until T007 removes them — this is intentional for safe rollback
- No database migrations needed
- No IAM policy changes needed
- WAF expression changes are NOT needed (existing prefix rule covers /v1/images/edits)
