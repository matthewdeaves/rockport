# Tasks: Rockport Bedrock Expansion

**Input**: Design documents from `/specs/013-bedrock-expansion/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: Verify prerequisites before making any changes

- [ ] T001 Verify LiteLLM version is post-January 2026 on the instance (check for Nova 2 textGenerationConfig fix, PR #18250). Current pinned version is `1.82.3` in `terraform/variables.tf` — if too old, update the variable before deploying
- [ ] T002 [P] Enable Bedrock model access in AWS console for: Llama 4 Scout, Llama 4 Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, GPT-OSS 120B, GPT-OSS 20B

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: IAM policy updates that MUST be complete before any new model can be invoked

- [ ] T003 Add `meta.llama4*` pattern to `InvokeUSModels` statement in `terraform/main.tf` (US regions, for Llama 4 Scout/Maverick foundation-model ARNs). Note: Nova 2 Lite needs NO IAM change — existing `amazon.nova-*` wildcard already covers `amazon.nova-2-lite-v1:0`
- [ ] T004 [P] Add `mistral.*` and `openai.gpt-oss*` patterns to `InvokeEUCrossRegionModels` statement in `terraform/main.tf` (EU regions, for Mistral and GPT-OSS models in eu-west-2)
- [ ] T005 Run `terraform plan` to verify IAM changes are correct and no existing permissions are affected
- [ ] T006 Run `terraform apply` to deploy IAM policy updates

**Checkpoint**: IAM permissions in place — new models can now be invoked via Bedrock

---

## Phase 3: User Story 1 - New Chat Models via Proxy (Priority: P1) MVP

**Goal**: Add 7 new Bedrock chat models to the proxy so clients can call them by name

**Independent Test**: Send `POST /v1/chat/completions` to each new model name and receive a valid response

### Implementation for User Story 1

- [ ] T007 [P] [US1] Add Llama 4 Scout entry to `config/litellm-config.yaml`: model_name `llama4-scout`, model `bedrock/us.meta.llama4-scout-17b-instruct-v1:0`, aws_region_name `us-east-1`
- [ ] T008 [P] [US1] Add Llama 4 Maverick entry to `config/litellm-config.yaml`: model_name `llama4-maverick`, model `bedrock/us.meta.llama4-maverick-17b-instruct-v1:0`, aws_region_name `us-east-1`
- [ ] T009 [P] [US1] Add Nova 2 Lite entry to `config/litellm-config.yaml`: model_name `nova-2-lite`, model `bedrock/eu.amazon.nova-2-lite-v1:0`, aws_region_name `eu-west-2`
- [ ] T010 [P] [US1] Add Mistral Large 3 entry to `config/litellm-config.yaml`: model_name `mistral-large-3`, model `bedrock/mistral.mistral-large-3-675b-instruct`, aws_region_name `eu-west-2`
- [ ] T011 [P] [US1] Add Ministral 8B entry to `config/litellm-config.yaml`: model_name `ministral-8b`, model `bedrock/mistral.ministral-3-8b-instruct`, aws_region_name `eu-west-2`
- [ ] T012 [P] [US1] Add GPT-OSS 120B entry to `config/litellm-config.yaml`: model_name `gpt-oss-120b`, model `bedrock/openai.gpt-oss-120b-1:0`, aws_region_name `eu-west-2`
- [ ] T013 [P] [US1] Add GPT-OSS 20B entry to `config/litellm-config.yaml`: model_name `gpt-oss-20b`, model `bedrock/openai.gpt-oss-20b-1:0`, aws_region_name `eu-west-2`
- [ ] T014 [US1] Push config to instance via `./scripts/rockport.sh config push` and verify all 7 models appear in `GET /v1/models`
- [ ] T015 [US1] Send basic chat completion request to each new model and verify valid response
- [ ] T016 [US1] Verify `--claude-only` keys return HTTP 403 for all new non-Anthropic models

**Checkpoint**: All 7 new models are accessible via the proxy, spend tracking works, key restrictions enforced

---

## Phase 4: User Story 2 - Prompt Caching Cost Reduction (Priority: P1)

**Goal**: Enable Bedrock prompt caching so Claude Code's repeated system prompts are cached, reducing costs by up to 90%

**Independent Test**: Send two identical requests with a large system prompt; verify the second shows `cache_read_input_tokens` in usage

### Implementation for User Story 2

- [ ] T017 [US2] Verify prompt caching works out of the box: send a request with `cache_control: {"type": "ephemeral"}` on a system message to a Claude model via the proxy, confirm response includes `cache_creation_input_tokens`
- [ ] T018 [US2] Send a second identical request and verify response includes `cache_read_input_tokens` with reduced cost in usage
- [ ] T019 [US2] Verify spend tracking in LiteLLM correctly applies cache-read rates ($0.30/MTok for Sonnet 4.6 instead of $3.00/MTok) via `./scripts/rockport.sh spend models`
- [ ] T020 [P] [US2] Add `cache_control_injection_points` to Claude model entries (and Nova 2 Lite) in `config/litellm-config.yaml` for server-side cache injection on system messages. Format: `cache_control_injection_points: [{location: message, role: system}]` under `litellm_params`. Per FR-013 SHOULD requirement — benefits non-Claude-Code clients. Nova 2 Lite also supports caching (75% savings on cache reads)
- [ ] T021 [US2] Verify Nova 2 Lite prompt caching also works (cache_read at $0.075/MTok vs $0.30/MTok standard)
- [ ] T021b [US2] Verify 1-hour TTL: send a request with `cache_control: {"type": "ephemeral", "ttl": "1h"}` to a Claude 4.5+ model, confirm Bedrock accepts the TTL (no error) and cache persists beyond the default 5-minute window

**Checkpoint**: Prompt caching verified working; spend tracking reflects cache-read discounts

---

## Phase 5: User Story 3 - Extended Thinking (Priority: P2)

**Goal**: Extended thinking / reasoning works for Claude 4.6, Nova 2 Lite, and GPT-OSS models via `reasoning_effort` parameter

**Independent Test**: Send a request with `reasoning_effort: "high"` to each supported model; verify reasoning content in response

### Implementation for User Story 3

- [ ] T022 [US3] Add `modify_params: true` to `litellm_settings` in `config/litellm-config.yaml` (handles multi-turn tool-use with thinking — avoids "Expected thinking but found tool_use" errors)
- [ ] T023 [US3] Push config update via `./scripts/rockport.sh config push`
- [ ] T024 [P] [US3] Verify Claude Sonnet 4.6 responds with thinking content when `reasoning_effort: "high"` is sent (LiteLLM translates to `thinking: {type: "adaptive"}`)
- [ ] T025 [P] [US3] Verify Nova 2 Lite responds with reasoning content when `reasoning_effort: "medium"` is sent (LiteLLM translates to `reasoningConfig: {type: "enabled", maxReasoningEffort: "medium"}`)
- [ ] T026 [P] [US3] Verify GPT-OSS 120B responds with reasoning content when `reasoning_effort: "high"` is sent (pass-through)
- [ ] T027 [US3] Verify that `reasoning_effort` sent to models that don't support it (e.g., `mistral-large-3`) is silently dropped via `drop_params: true`

**Checkpoint**: Extended thinking works across Claude, Nova 2, and GPT-OSS model families

---

## Phase 6: User Story 4 - Bedrock Guardrails (Priority: P3)

**Goal**: Optional Bedrock Guardrails for content filtering, PII masking, and contextual grounding

**Independent Test**: Create a guardrail, configure it in LiteLLM, send blocked content, verify HTTP 400 error

### Implementation for User Story 4

- [ ] T028 [US4] Create `terraform/guardrails.tf` with `aws_bedrock_guardrail` resource behind a `var.enable_guardrails` toggle (default `false`). Include content policy (violence, hate, insults — MEDIUM strength), PII policy (EMAIL, PHONE → ANONYMIZE), and word policy (managed profanity list)
- [ ] T029 [US4] Add `enable_guardrails` variable (type bool, default false) to `terraform/variables.tf`
- [ ] T030 [US4] Add `bedrock:ApplyGuardrail` IAM permission to `terraform/main.tf`, conditional on `var.enable_guardrails` — scoped to the guardrail ARN in the deployment region
- [ ] T031 [US4] Add guardrail ID and version as Terraform outputs in `terraform/outputs.tf` (conditional on `var.enable_guardrails`)
- [ ] T032 [US4] Run `terraform plan` with `enable_guardrails=true` to verify the guardrail resource, IAM, and outputs are correct
- [ ] T033 [US4] Run `terraform apply` with `enable_guardrails=true` to create the guardrail
- [ ] T034 [US4] Add commented-out `guardrails:` section to `config/litellm-config.yaml` with example configuration referencing the Terraform output guardrail ID, `mode: pre_call`, `default_on: false`
- [ ] T035 [US4] Uncomment guardrail config with `mode: pre_call`, push to instance, and test: send a request with violent content → verify HTTP 400 with guardrail violation message. Note: `during_call` and `post_call` modes are also supported but pre_call is recommended for lowest-cost blocking (prevents LLM invocation on blocked content)
- [ ] T036 [US4] Test PII masking: send a request containing an email address with `mask_request_content: true` → verify email is anonymized before reaching the model
- [ ] T037 [US4] Verify that with guardrails disabled (commented out or `default_on: false`), there is zero overhead on normal requests
- [ ] T037b [US4] Test per-model guardrail: add `guardrails: ["rockport-guard"]` to a single model entry in `config/litellm-config.yaml`, push config, verify guardrail runs only for that model and not for others

**Checkpoint**: Guardrails work when enabled; zero impact when disabled

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Testing, documentation, and cleanup across all user stories

- [ ] T038 [P] Extend `tests/smoke-test.sh` following existing patterns: (a) verify all 7 new model names appear in `GET /v1/models` response, (b) send a basic streaming chat completion to one representative new model (e.g., `nova-2-lite`) to verify end-to-end connectivity — avoid testing all 7 to keep smoke test cost low. Follow explicit bash error handling per constitution
- [ ] T039 [P] Update `CLAUDE.md` with: new model list and model IDs, prompt caching notes (automatic via cache_control, 1-hour TTL for Claude 4.5+), extended thinking notes (reasoning_effort support per model family), guardrails documentation (Terraform resource, LiteLLM config, IAM permission)
- [ ] T040 Run full smoke test suite (`tests/smoke-test.sh`) to verify all existing and new models work
- [ ] T041 Verify all existing models (Claude, DeepSeek, Qwen, Kimi, Nova v1, image, video) still work correctly after all changes
- [ ] T042 Run `./scripts/rockport.sh spend models` to verify spend tracking reports costs for all new models

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (IAM must be deployed first)
- **User Story 1 (Phase 3)**: Depends on Foundational (Phase 2) — models need IAM permissions
- **User Story 2 (Phase 4)**: Can start after Foundational — independent of US1 (caching works on existing Claude models)
- **User Story 3 (Phase 5)**: Can start after Foundational — independent of US1/US2 (thinking works on existing Claude models, but benefits from US1 for Nova 2/GPT-OSS testing)
- **User Story 4 (Phase 6)**: Can start after Foundational — fully independent (guardrails are a separate Bedrock feature)
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (New Models)**: Independent — only needs IAM from Phase 2
- **US2 (Prompt Caching)**: Independent — works on existing Claude models. Benefits from US1 for Nova 2 cache testing
- **US3 (Extended Thinking)**: Independent — works on existing Claude models. Benefits from US1 for Nova 2 and GPT-OSS thinking testing
- **US4 (Guardrails)**: Fully independent — separate Terraform resource, separate LiteLLM config section

### Parallel Opportunities

- T007-T013 (all 7 model entries) can all run in parallel — different config entries, no conflicts
- T024-T026 (thinking verification for 3 model families) can all run in parallel
- T038-T039 (smoke tests and docs) can run in parallel
- US2 and US3 can start in parallel after Phase 2 if US1 is deferred
- US4 is fully independent and can run in parallel with any other user story

---

## Parallel Example: User Story 1

```bash
# Launch all model entries in parallel (T007-T013):
Task: "Add Llama 4 Scout entry to config/litellm-config.yaml"
Task: "Add Llama 4 Maverick entry to config/litellm-config.yaml"
Task: "Add Nova 2 Lite entry to config/litellm-config.yaml"
Task: "Add Mistral Large 3 entry to config/litellm-config.yaml"
Task: "Add Ministral 8B entry to config/litellm-config.yaml"
Task: "Add GPT-OSS 120B entry to config/litellm-config.yaml"
Task: "Add GPT-OSS 20B entry to config/litellm-config.yaml"
# Then sequentially: push config → test responses → verify key restrictions
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (verify LiteLLM version, enable model access)
2. Complete Phase 2: Foundational (IAM policy updates, terraform apply)
3. Complete Phase 3: User Story 1 (add models to config, push, test)
4. **STOP and VALIDATE**: All 7 models respond via proxy
5. Deploy/demo if ready — immediate value with new model access

### Incremental Delivery

1. Setup + Foundational → IAM ready
2. Add US1 (New Models) → Test → Deploy (MVP: 7 new models accessible)
3. Add US2 (Prompt Caching) → Test → Deploy (cost reduction live)
4. Add US3 (Extended Thinking) → Test → Deploy (reasoning enabled)
5. Add US4 (Guardrails) → Test → Deploy (optional safety layer)
6. Polish → Smoke tests, docs → Final deploy

### Recommended Order

US1 first (prerequisite for testing US2/US3 with new models), then US2 (highest cost impact), then US3 (capability enhancement), then US4 (optional safety layer). US4 can be deferred or skipped entirely if not needed.

---

## Notes

- All model entries in T007-T013 edit the same file (`config/litellm-config.yaml`) but different sections — safe to do in parallel or batch
- T003-T004 edit the same file (`terraform/main.tf`) but different IAM statements — can be done in parallel but easier to batch
- No custom code is written — all changes are config (YAML), infrastructure (HCL), and bash (smoke tests)
- Guardrails (US4) are entirely optional and behind a variable toggle — safe to skip or defer
- Prompt caching (US2) may require zero changes — just verification that existing LiteLLM behavior works correctly
