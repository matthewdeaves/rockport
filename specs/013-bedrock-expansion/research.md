# Research: Rockport Bedrock Expansion

**Date**: 2026-03-22 | **Branch**: `013-bedrock-expansion`

## R1: LiteLLM Model Support for New Bedrock Models

**Decision**: All 7 new models are fully supported by LiteLLM via the `bedrock_converse` provider. Use standard `bedrock/` prefix model IDs.

**Rationale**: Verified by inspecting `/tmp/litellm/model_prices_and_context_window.json` — all models have entries with correct pricing, feature flags, and max token limits.

**Key findings per model**:

| Model | LiteLLM ID | Cross-Region | Region | Input $/MTok | Output $/MTok |
|-------|-----------|-------------|--------|-------------|--------------|
| Llama 4 Scout 17B | `bedrock/us.meta.llama4-scout-17b-instruct-v1:0` | `us.` only | us-east-1 | $0.17 | $0.66 |
| Llama 4 Maverick 17B | `bedrock/us.meta.llama4-maverick-17b-instruct-v1:0` | `us.` only | us-east-1 | $0.24 | $0.97 |
| Nova 2 Lite | `bedrock/eu.amazon.nova-2-lite-v1:0` | `eu.`, `us.`, `apac.`, `global.` | eu-west-2 | $0.33 | $2.75 |
| Mistral Large 3 | `bedrock/mistral.mistral-large-3-675b-instruct` | None | eu-west-2 | $0.50 | $1.50 |
| Ministral 8B | `bedrock/mistral.ministral-3-8b-instruct` | None | eu-west-2 | $0.15 | $0.15 |
| GPT-OSS 120B | `bedrock/openai.gpt-oss-120b-1:0` | None | eu-west-2 | $0.15 | $0.60 |
| GPT-OSS 20B | `bedrock/openai.gpt-oss-20b-1:0` | None | eu-west-2 | $0.07 | $0.30 |

**Region strategy update**: GPT-OSS and Mistral models are available in eu-west-2 (confirmed via AWS docs). This means they can stay in the same region as existing Claude/Nova/DeepSeek models. Only Llama 4 requires US cross-region inference profiles (no EU availability).

**Alternatives considered**:
- `bedrock_mantle` provider for GPT-OSS — rejected because it uses a different auth mechanism (Bearer token, not SigV4) and would add complexity
- Direct in-region Llama 4 — rejected because `us.` cross-region profile provides better availability across 4 US regions

**Gotchas documented**:
- Llama 4: `supports_tool_choice: false` — existing `drop_params: true` handles this
- Mistral/GPT-OSS: No `:0` version suffix in Mistral model IDs; GPT-OSS uses `-1:0` suffix
- GPT-OSS: Native structured outputs broken on Bedrock; LiteLLM falls back to synthetic tool injection
- No Marketplace subscription required for any of these models (unlike Stability AI)
- Model access must be enabled in Bedrock console before first use

---

## R2: Prompt Caching via LiteLLM

**Decision**: Prompt caching works automatically with zero config changes. LiteLLM translates `cache_control` → Bedrock `cachePoint` blocks transparently.

**Rationale**: Verified in LiteLLM source code (`converse_transformation.py` line 1102). The `_get_cache_point_block()` method checks for `cache_control` on each content block and emits a `cachePoint` block. No beta header needed for Bedrock (unlike direct Anthropic API).

**Key findings**:
- Claude Code already sends `cache_control: {"type": "ephemeral"}` on system prompts
- LiteLLM translates this to Bedrock `ContentBlock(cachePoint={"type": "default"})` blocks
- 1-hour TTL: Supported for Claude 4.5+ on Bedrock via `cache_control: {"type": "ephemeral", "ttl": "1h"}`. LiteLLM checks `is_claude_4_5_on_bedrock()` before including TTL
- Cache read cost: $0.30/MTok for Sonnet 4.6 (vs $3.00/MTok standard input) — 90% savings
- Cache write cost: $3.75/MTok (25% premium over standard input)
- LiteLLM tracks `cacheReadInputTokens` and `cacheWriteInputTokens` in usage automatically
- Optional `cache_control_injection_points` config injects cache points server-side for non-cache-aware clients
- Nova 2 Lite also supports caching: cache read $0.075/MTok (vs $0.30/MTok standard) — 75% savings

**Alternatives considered**:
- Server-side-only caching (no client pass-through) — rejected because Claude Code already sends the right headers
- Custom caching middleware — rejected per constitution (LiteLLM-first, no custom code)

---

## R3: Extended Thinking via LiteLLM

**Decision**: Extended thinking works via `reasoning_effort` parameter with zero config changes. LiteLLM translates per model family automatically.

**Rationale**: Verified in LiteLLM source code (`converse_transformation.py`). Three distinct translation paths exist:

| Model Family | `reasoning_effort` mapping | Bedrock parameter |
|-------------|--------------------------|-------------------|
| Claude 4.6 (Sonnet/Opus) | Any value → `{"type": "adaptive"}` | `additionalModelRequestFields.thinking` |
| Claude 4.5 and earlier | `"low"` → 1024, `"medium"` → 2048, `"high"` → 4096 budget_tokens | `additionalModelRequestFields.thinking` |
| Nova 2 Lite | `"low"`, `"medium"`, `"high"` → direct mapping | `additionalModelRequestFields.reasoningConfig` |
| GPT-OSS | Pass-through as-is | `additionalModelRequestFields.reasoning_effort` |

**Key findings**:
- Claude Code sends `reasoning_effort` — LiteLLM handles translation
- Response includes `reasoning_content` (string) and `thinking_blocks` (structured list)
- Multi-turn tool-use caveat: If `thinking` is set but assistant message has no `thinking_blocks`, LiteLLM drops `thinking` to avoid Bedrock error — requires `litellm.modify_params = True` (config: `litellm_settings.modify_params: true`)
- Nova 2: `reasoning_effort: "high"` incompatible with explicit `temperature`/`topP`/`topK`
- `drop_params: true` (already set) handles unsupported models gracefully

**Alternatives considered**:
- Explicit `thinking` dict only — rejected because `reasoning_effort` is what Claude Code sends
- Disabling thinking for non-Claude models — rejected because Nova 2 and GPT-OSS both benefit

---

## R4: Bedrock Guardrails via LiteLLM

**Decision**: Use LiteLLM's proxy guardrail system (ApplyGuardrail API), configured in `litellm-config.yaml`. Terraform creates the guardrail resource. Guardrails are optional.

**Rationale**: LiteLLM has a dedicated Bedrock guardrail integration (`proxy/guardrails/guardrail_hooks/bedrock_guardrails.py`) that calls the `ApplyGuardrail` API independently of the model invocation. This means guardrails work with ALL models, not just Bedrock models.

**Architecture**:
```
Client → LiteLLM proxy
           ├─ pre_call: POST bedrock-runtime/guardrail/{id}/version/{v}/apply (SigV4)
           │   └─ BLOCKED? → HTTP 400 back to client
           │   └─ ANONYMIZED? → Replace content, continue
           ├─ LLM call (Bedrock Converse API)
           ├─ during_call: Same guardrail check in parallel
           └─ post_call: Check input + output together
```

**Configuration approach**:
```yaml
# litellm-config.yaml
guardrails:
  - guardrail_name: "rockport-guard"
    litellm_params:
      guardrail: bedrock
      mode: "pre_call"
      guardrailIdentifier: <from terraform output>
      guardrailVersion: "1"
      aws_region_name: eu-west-2
      default_on: false  # opt-in, not default
```

**Terraform resource**: `aws_bedrock_guardrail` + `aws_bedrock_guardrail_version`
- Content policy: Configurable filter strengths (LOW/MEDIUM/HIGH) for violence, hate, insults, sexual, misconduct
- PII policy: ANONYMIZE or BLOCK for email, phone, SSN, etc.
- Word policy: Managed profanity list
- Contextual grounding: Hallucination detection (threshold-based)

**IAM**: Instance role needs `bedrock:ApplyGuardrail` on the guardrail ARN. Guardrails use the EC2 instance role's ambient credentials by default (same as model invocation) — no separate credential config needed.

**Mode recommendation**: `during_call` is preferred over `pre_call` for production use. `during_call` runs the guardrail check in parallel with the LLM call — total latency is max(guardrail, LLM) instead of guardrail + LLM. `pre_call` blocks the LLM call until the guardrail completes (adds ~1-2s). Use `pre_call` only if you need to mask PII before it reaches the model.

**Scope options** (all supported by LiteLLM):
- Global: `default_on: true`
- Per-model: `guardrails` field in model_list entries
- Per-request: Client sends `guardrails: ["rockport-guard"]` in request body

**Alternatives considered**:
- Native Converse `guardrailConfig` pass-through — rejected because it only works with Bedrock models and requires client-side knowledge of guardrail IDs
- Custom content filtering — rejected per constitution (no custom code)
- Always-on guardrails — rejected because they add latency and cost; should be operator's choice

---

## R5: IAM Policy Updates

**Decision**: Add new model family patterns to the existing `bedrock_invoke` IAM policy. Add `bedrock:ApplyGuardrail` as a separate policy statement.

**Current IAM structure** (from `terraform/main.tf`):
- `InvokeEUCrossRegionModels`: EU regions, patterns for `anthropic.claude-*`, `amazon.nova-*`, `amazon.titan-*`, `deepseek.*`, `qwen.*`, `moonshotai.*`
- `InvokeUSModels`: US regions, patterns for `stability.*`, `luma.*`, `amazon.nova-*`, `amazon.titan-*`
- `InferenceProfiles`: All regions, wildcard `inference-profile/*`

**Required additions**:
1. EU statement: Add `mistral.*`, `openai.gpt-oss*` patterns (both available in eu-west-2)
2. US statement: Add `meta.llama4*` pattern (Llama 4 is US-only)
3. New statement: `bedrock:ApplyGuardrail` on guardrail ARN (conditional on guardrail being created)

**NOT needed**: Nova 2 Lite requires NO IAM change — the existing `amazon.nova-*` wildcard in `InvokeEUCrossRegionModels` already covers `amazon.nova-2-lite-v1:0`. The `InferenceProfiles` statement covers `inference-profile/*` for all regions, handling the `eu.` cross-region profile.

**Note**: `meta.llama4*` uses `us.` cross-region inference profiles, which are already covered by the `InferenceProfiles` statement. However, the underlying foundation-model ARNs also need explicit permission in the US regions.

---

## R6: Smoke Test Updates

**Decision**: Extend existing smoke test to cover new models with basic chat completion requests.

**Current smoke test** (`tests/smoke-test.sh`): Checks health endpoint and model list.

**Required additions**:
- Send basic chat completion to each new model
- Verify response contains valid choices
- Optionally verify `reasoning_effort` produces thinking content (Nova 2 Lite, GPT-OSS)
- Follow explicit bash error handling (constitution VI)
