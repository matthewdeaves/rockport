# Tasks: Image Generation via Bedrock

**Input**: Design documents from `/specs/002-image-generation/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Not explicitly requested. Smoke test updates included as they are part of existing test infrastructure.

**Organization**: Tasks grouped by user story for independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Terraform and config changes that enable image generation

- [x] T001 [P] Add us-west-2 to bedrock_regions in terraform/main.tf
- [x] T002 [P] Add /v1/images/generations to WAF allowlist in terraform/waf.tf
- [x] T003 [P] Add image model entries (nova-canvas, titan-image-v2, sd3-large) to config/litellm-config.yaml with aws_region_name: us-west-2

**Checkpoint**: Infrastructure ready for image generation after `terraform apply` and `config push`

---

## Phase 2: User Story 1 — Generate Images via OpenAI-Compatible API (Priority: P1) MVP

**Goal**: Users can call `/v1/images/generations` through Rockport and get images back from Bedrock models.

**Independent Test**: `curl -X POST https://<endpoint>/v1/images/generations -H "Authorization: Bearer sk-<key>" -d '{"model":"nova-canvas","prompt":"a red circle","n":1,"size":"1024x1024"}' | jq '.data[0].b64_json' | head -c 20` returns base64 data.

### Implementation for User Story 1

- [x] T004 [US1] Add image generation tests to tests/smoke-test.sh — test text-to-image (call /v1/images/generations with nova-canvas, verify b64_json in response) and image-to-image (provide source image, verify transformed image returned)
- [ ] T005 [US1] Deploy and validate: run terraform apply, config push, then smoke test to confirm image generation works end-to-end (MANUAL — requires live infrastructure)

**Checkpoint**: Image generation works via API. Any key can generate images.

---

## Phase 3: User Story 2 — Claude Code Keys Restricted to Anthropic Models (Priority: P1)

**Goal**: Claude Code keys only see Anthropic models. Image models and non-Anthropic chat models are hidden and blocked.

**Independent Test**: Create a Claude-only key, call `/v1/models` and verify only Anthropic models appear. Call `/v1/images/generations` with that key and verify rejection.

**Depends on**: Phase 2 (need image models configured to test restriction)

### Implementation for User Story 2

- [x] T006 [US2] Define CLAUDE_MODELS variable in scripts/rockport.sh containing the list of Anthropic model names (claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5-20251001, claude-sonnet-4-5-20250929, claude-opus-4-5-20251101)
- [x] T007 [US2] Update cmd_setup_claude() in scripts/rockport.sh to pass "models" array (from CLAUDE_MODELS) in the /key/generate payload so generated keys are restricted to Anthropic models only

**Checkpoint**: `setup-claude` creates restricted keys. Claude Code users can't see or call image models.

---

## Phase 4: User Story 3 — Admin Creates Keys with Model Scope (Priority: P2)

**Goal**: `rockport key create` supports `--claude-only` flag. Without it, keys get full access.

**Independent Test**: Run `rockport key create test1 --claude-only`, verify restricted. Run `rockport key create test2`, verify full access.

### Implementation for User Story 3

- [x] T008 [US3] Add --claude-only flag parsing to cmd_key_create() in scripts/rockport.sh — when set, include "models" array (from CLAUDE_MODELS) in the /key/generate payload
- [x] T009 [US3] Update usage/help text in scripts/rockport.sh to document --claude-only flag for key create command

**Checkpoint**: Admin can create both restricted and unrestricted keys via CLI.

---

## Phase 5: User Story 4 — Start Instance Quickly via CLI (Priority: P2)

**Goal**: `rockport start` waits for health check, not just EC2 running state. Bash alias available for quick access.

**Independent Test**: Stop instance, run `rockport start`, verify it reports healthy (not just "running").

### Implementation for User Story 4

- [x] T010 [US4] Enhance cmd_start() in scripts/rockport.sh to poll the tunnel health endpoint (get_tunnel_url + /health) after instance-running, with 120s timeout and 5s interval, reporting ready only when health returns 200
- [x] T011 [US4] Add alias suggestion to rockport init output in scripts/rockport.sh — print instruction to add `alias rockport-start='<repo-path>/scripts/rockport.sh start'` to shell profile

**Checkpoint**: `rockport start` gives definitive "ready" confirmation. User knows about the alias shortcut.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and final validation

- [x] T012 [P] Update CLAUDE.md with image model info, key restriction notes, us-west-2 routing note, and /v1/images/generations WAF entry
- [ ] T013 Run quickstart.md validation — verify the Python and curl examples in specs/002-image-generation/quickstart.md work against live deployment (MANUAL — requires live infrastructure)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately. All T001-T003 can run in parallel.
- **Phase 2 (US1 — Image Gen)**: Depends on Phase 1. Requires deploy (`terraform apply` + `config push`).
- **Phase 3 (US2 — Claude Key Restriction)**: Depends on Phase 2 (need image models to test restriction).
- **Phase 4 (US3 — Key Flags)**: Depends on Phase 3 (reuses CLAUDE_MODELS variable from T006).
- **Phase 5 (US4 — Start Command)**: Independent of Phases 2-4. Can run in parallel after Phase 1.
- **Phase 6 (Polish)**: Depends on all prior phases.

### User Story Dependencies

- **US1 (P1)**: Start after Phase 1 — no story dependencies
- **US2 (P1)**: Start after US1 — needs image models to validate restriction works
- **US3 (P2)**: Start after US2 — reuses CLAUDE_MODELS from T006
- **US4 (P2)**: Independent — can run in parallel with US2/US3

### Parallel Opportunities

- T001, T002, T003 can all run in parallel (different files)
- T012 can run in parallel with any phase (documentation only)
- US4 (T010, T011) can run in parallel with US2/US3

---

## Parallel Example: Phase 1

```bash
# All three setup tasks touch different files:
Task: "Add us-west-2 to bedrock_regions in terraform/main.tf"
Task: "Add /v1/images/generations to WAF allowlist in terraform/waf.tf"
Task: "Add image model entries to config/litellm-config.yaml"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T003)
2. Deploy: `terraform apply` + `rockport config push`
3. Complete Phase 2: US1 smoke test (T004-T005)
4. **STOP and VALIDATE**: Image generation works end-to-end
5. Ship it — image gen is usable

### Incremental Delivery

1. Phase 1 (Setup) → Foundation ready
2. Phase 2 (US1 — Image Gen) → Test → Deploy (MVP!)
3. Phase 3 (US2 — Claude Key Restriction) → Test → Deploy
4. Phase 4 (US3 — Key Flags) → Test → Deploy
5. Phase 5 (US4 — Start Command) → Test → Deploy
6. Phase 6 (Polish) → Final validation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story
- Total: 13 tasks across 6 phases
- All changes are to existing files — no new files created in the codebase
- Image models require manual enablement in AWS Bedrock console for us-west-2 before deploy
