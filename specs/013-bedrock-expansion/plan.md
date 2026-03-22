# Implementation Plan: Rockport Bedrock Expansion

**Branch**: `013-bedrock-expansion` | **Date**: 2026-03-22 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/013-bedrock-expansion/spec.md`

## Summary

Add 7 new Bedrock chat models (Llama 4 Scout/Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, GPT-OSS 120B/20B), enable prompt caching for Claude models, support extended thinking across multiple model families, and add optional Bedrock Guardrails. All features work through LiteLLM configuration — no custom application code. CLI health checks and smoke tests updated to cover new models.

**Technical approach**: Config-driven. New models are `litellm-config.yaml` entries. Prompt caching works automatically (LiteLLM translates `cache_control` → Bedrock `cachePoint`). Extended thinking works automatically (`reasoning_effort` → model-specific parameters). Guardrails require a Terraform resource + config section. IAM policies updated for new model families. Smoke tests extended per FR-026. CLI health verified per FR-025.

## Technical Context

**Language/Version**: Bash (scripts), HCL (Terraform), YAML (LiteLLM config)
**Primary Dependencies**: LiteLLM (post-Jan 2026), Terraform (AWS + Cloudflare providers)
**Storage**: PostgreSQL 15 on-instance (existing — spend tracking)
**Testing**: Bash smoke tests (`tests/smoke-test.sh`)
**Target Platform**: Linux (Amazon Linux 2023, EC2 t3.small)
**Project Type**: Infrastructure config (IaC + proxy config)
**Performance Goals**: All models respond within 30s; guardrail pre_call adds <2s latency
**Constraints**: 2GB RAM (t3.small), 1280MB LiteLLM MemoryMax, 256MB sidecar MemoryMax
**Scale/Scope**: 1 operator, ~8 hours/day, handful of accounts

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure. Models are pay-per-token via Bedrock. Guardrails add ~$0.001/request when enabled. No new EC2 instances, no ALB, no RDS. |
| II. Security | PASS | IAM policy updated with least-privilege model patterns. Guardrails add security (content filtering, PII masking). No new auth code. |
| III. LiteLLM-First | PASS | All features use LiteLLM configuration. No custom code. Models = config entries. Caching = pass-through. Thinking = pass-through. Guardrails = LiteLLM's built-in hook system. |
| IV. Scope Containment | PASS | Serves core use case (Claude Code → Rockport → Bedrock). No dashboard, no billing, no custom hosting. "Prompt caching" in constitution out-of-scope list refers to custom caching — this is Bedrock infrastructure caching passed through LiteLLM, not custom code. |
| V. AWS London + Cloudflare | PASS | 5 of 7 new models run in eu-west-2 (Mistral, GPT-OSS, Nova 2 Lite via eu. profile). Only Llama 4 requires US (us. cross-region). Matches existing pattern for image/video models. |
| VI. Explicit Bash Error Handling | PASS | Smoke test updates will use explicit error handling. No `set -euo pipefail`. |

**Post-Phase 1 re-check**: All gates still pass. No constitution violations.

## Project Structure

### Documentation (this feature)

```text
specs/013-bedrock-expansion/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: LiteLLM research, model IDs, region availability, CLI health analysis
├── data-model.md        # Phase 1: Config entities and relationships
├── quickstart.md        # Phase 1: Verification steps
├── contracts/
│   └── model-routing.md # Phase 1: Model name → Bedrock ID mapping, feature matrix
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
config/
└── litellm-config.yaml      # 7 new model entries, modify_params, optional guardrails

terraform/
├── main.tf                   # IAM policy updates (new model patterns + ApplyGuardrail)
├── variables.tf              # enable_guardrails variable (bool, default false)
├── outputs.tf                # Guardrail ID/version outputs (conditional)
└── guardrails.tf             # NEW: Optional aws_bedrock_guardrail + version (behind variable toggle)

scripts/
└── rockport.sh               # Verified: no changes needed for chat model health probes (FR-025)

tests/
└── smoke-test.sh             # Extended: 7 model list checks + 1 live nova-2-lite streaming chat (FR-026)

CLAUDE.md                     # Updated: new models, caching notes, guardrails docs
```

**Structure Decision**: No new directories or source files except `terraform/guardrails.tf`. All other changes are to existing files. CLI (`rockport.sh`) verified to not need changes for chat model health probes — the hardcoded case statement (lines 745-751) is only for image model Bedrock ID → LiteLLM name mapping, which is irrelevant for chat models.

## Implementation Phases

### Phase 1: New Models (P1)

**Files**: `config/litellm-config.yaml`, `terraform/main.tf`

1. Add 7 model entries to `litellm-config.yaml`:
   - Llama 4 Scout/Maverick with `us.` prefix, `us-east-1` region
   - Nova 2 Lite with `eu.` prefix, `eu-west-2` region
   - Mistral Large 3, Ministral 8B, GPT-OSS 120B/20B with `eu-west-2` region (no cross-region needed)

2. Update IAM policy in `terraform/main.tf`:
   - Add `mistral.*` and `openai.gpt-oss*` to `InvokeEUCrossRegionModels` statement
   - Add `meta.llama4*` to `InvokeUSModels` statement

3. Enable Bedrock model access in AWS console for all new models (manual step)

### Phase 2: Prompt Caching (P1)

**Files**: `config/litellm-config.yaml` (optional `cache_control_injection_points`)

1. Verify prompt caching works out of the box (Claude Code sends `cache_control`, LiteLLM translates)
2. Optionally add `cache_control_injection_points` to Claude model entries for server-side injection
3. Verify spend tracking reflects cache-read rates

**Note**: This may require zero code changes — just verification that existing LiteLLM behavior works correctly with Bedrock.

### Phase 3: Extended Thinking (P2)

**Files**: `config/litellm-config.yaml`

1. Add `modify_params: true` to `litellm_settings` (handles multi-turn tool-use with thinking)
2. Verify `reasoning_effort` works for Claude 4.6, Nova 2 Lite, and GPT-OSS
3. No model-specific config needed — LiteLLM handles translation automatically

### Phase 4: Guardrails (P3)

**Files**: `terraform/guardrails.tf` (new), `terraform/variables.tf`, `terraform/outputs.tf`, `terraform/main.tf` (IAM), `config/litellm-config.yaml`

1. Create `terraform/guardrails.tf` with `aws_bedrock_guardrail` resource (behind `enable_guardrails` variable toggle — defaults to `false`)
2. Add `bedrock:ApplyGuardrail` IAM permission (conditional on guardrail being created)
3. Add `guardrails:` section to `litellm-config.yaml` (commented out by default)
4. Document configuration in CLAUDE.md

### Phase 5: Testing, CLI Verification & Docs

**Files**: `tests/smoke-test.sh`, `CLAUDE.md`

1. **Smoke tests (FR-026)**: Add 7 model name checks to model list verification (test 4), add 1 live streaming chat completion to `nova-2-lite`
2. **CLI health verification (FR-025)**: Run `rockport.sh status` after deployment, confirm all 7 new models appear as healthy. If any fail health probe, add to exclusion pattern in `cmd_status()` and implement manual probing
3. Update CLAUDE.md with new models, caching notes, thinking notes, guardrails documentation
4. Run full smoke test suite

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| LiteLLM version too old for Nova 2 | Low | High | Check version during deploy; document minimum version |
| Marketplace subscription not activated | Medium | Low | Smoke test catches this; document in quickstart |
| Prompt caching not working with cross-region profiles | Low | Medium | Verify with test request; fall back to in-region if needed |
| Guardrails add too much latency | Low | Low | Guardrails are optional; `during_call` mode runs in parallel |
| Memory pressure from additional model routing | Very Low | Medium | No memory increase — models are config entries, not loaded into memory |
| New chat model fails LiteLLM health probe | Very Low | Low | All chat models accept `max_tokens`; add exclusion pattern if needed (FR-025) |

## Complexity Tracking

No constitution violations. No complexity tracking needed.
