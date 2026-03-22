# Feature Specification: Rockport Bedrock Expansion

**Feature Branch**: `013-bedrock-expansion`
**Created**: 2026-03-22
**Status**: Draft
**Input**: User description: "Add new Bedrock models (Llama 4, Nova 2 Lite, Mistral Large 3, GPT-OSS), enable prompt caching, extended thinking, and optional Bedrock Guardrails to the Rockport LiteLLM proxy"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - New Chat Models via Proxy (Priority: P1)

An operator adds new Bedrock models to Rockport so that any OpenAI SDK client can call Llama 4 Scout/Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, and GPT-OSS 120B/20B through the same proxy endpoint used for Claude. Clients specify the model name in their request and get responses — no Bedrock credentials, no SDK changes.

**Why this priority**: Expands model coverage from 5 chat model families to 9. Cheap models (Nova 2 Lite at $0.30/MTok input, GPT-OSS 20B at $0.07/MTok) give operators cost-effective alternatives for simple tasks. Llama 4 Scout's 3.5M context window and multimodal support opens new use cases.

**Independent Test**: Can be fully tested by sending a chat completion request to each new model name and receiving a valid response. Delivers immediate value — new model access — with no changes to existing models.

**Acceptance Scenarios**:

1. **Given** the proxy is running with new models configured, **When** a client sends `POST /v1/chat/completions` with `model: "llama4-scout"`, **Then** the proxy routes the request to Bedrock's `us.meta.llama4-scout-17b-instruct-v1:0` and returns a valid chat completion response
2. **Given** the proxy is running, **When** a client sends a request with `model: "nova-2-lite"`, **Then** the proxy routes to `eu.amazon.nova-2-lite-v1:0` and returns a valid response
3. **Given** the proxy is running, **When** a client sends a request with `model: "gpt-oss-120b"`, **Then** the proxy routes to `openai.gpt-oss-120b-1:0` in eu-west-2 and returns a valid response
4. **Given** the proxy is running, **When** a client sends a request with `model: "mistral-large-3"`, **Then** the proxy routes to `mistral.mistral-large-3-675b-instruct` and returns a valid response
5. **Given** a key created with `--claude-only`, **When** that key sends a request to any new non-Anthropic model, **Then** the proxy returns HTTP 403
6. **Given** the proxy is running, **When** a client lists models via `GET /v1/models`, **Then** all new models appear in the response

---

### User Story 2 - Prompt Caching Cost Reduction (Priority: P1)

Claude Code sends the same large system prompt on every request. Bedrock prompt caching with 1-hour TTL means the system prompt is cached after the first request, reducing input token costs by up to 90% and latency by up to 85% for subsequent requests within the cache window. This works automatically — Claude Code already sends `cache_control` headers, and LiteLLM translates them to Bedrock `cachePoint` blocks with no extra configuration.

**Why this priority**: Tied for highest priority because it directly reduces the operator's largest cost (Claude token spend) with minimal implementation effort. LiteLLM already handles `cache_control` → `cachePoint` translation. The main work is verification, optional server-side injection config for non-Claude-Code clients, and ensuring spend tracking uses cache-read rates.

**Independent Test**: Can be tested by sending two identical requests with a large system prompt and verifying the second request shows `cache_read_input_tokens` in the usage response, with lower cost.

**Acceptance Scenarios**:

1. **Given** a Claude model is configured with the `eu.` cross-region prefix, **When** Claude Code sends a request with `cache_control` blocks in the system prompt, **Then** LiteLLM translates them to Bedrock `cachePoint` blocks and the response usage includes `cache_read_input_tokens` on subsequent requests
2. **Given** prompt caching is working, **When** the operator checks spend tracking, **Then** cached token costs are calculated at the cache-read rate ($0.30/MTok for Sonnet 4.6 instead of $3.00/MTok)
3. **Given** a non-Claude-Code client sends requests without `cache_control`, **When** `cache_control_injection_points` is configured for the model, **Then** LiteLLM automatically injects cache points on system messages
4. **Given** Claude 4.5+ models on Bedrock, **When** the system sends cache_control with `ttl: "1h"`, **Then** the cache persists for 1 hour instead of the default 5 minutes

---

### User Story 3 - Extended Thinking (Priority: P2)

Clients can enable extended thinking / chain-of-thought reasoning for supported models. Claude 4.6 models use `reasoning_effort` mapped to adaptive thinking; Nova 2 Lite uses `reasoning_effort` mapped to thinking intensity levels (low/medium/high); GPT-OSS models pass `reasoning_effort` through directly. The proxy transparently translates these to the correct Bedrock API parameters per model family.

**Why this priority**: Enhances model capability for complex tasks. Claude Code already sends `reasoning_effort` — this ensures it works correctly through the proxy for all supported models. Lower priority than caching because it doesn't reduce cost.

**Independent Test**: Can be tested by sending a request with `reasoning_effort: "high"` to each supported model and verifying the response includes reasoning content.

**Acceptance Scenarios**:

1. **Given** Claude Sonnet 4.6 is configured, **When** a client sends `reasoning_effort: "high"`, **Then** LiteLLM translates to `thinking: {type: "adaptive"}` for Bedrock and the response includes thinking content
2. **Given** Nova 2 Lite is configured, **When** a client sends `reasoning_effort: "medium"`, **Then** LiteLLM translates to `reasoningConfig: {type: "enabled", maxReasoningEffort: "medium"}` for Bedrock
3. **Given** GPT-OSS 120B is configured, **When** a client sends `reasoning_effort: "high"`, **Then** the parameter is passed through to Bedrock and reasoning content appears in the response
4. **Given** a model that does not support reasoning, **When** a client sends `reasoning_effort`, **Then** the parameter is silently dropped (existing `drop_params: true` behavior)

---

### User Story 4 - Bedrock Guardrails (Priority: P3)

An operator can optionally enable Bedrock Guardrails to add content filtering, PII detection/masking, and contextual grounding to proxy requests. Guardrails are defined in Terraform, configured in LiteLLM, and can be applied globally, per-model, or per-request. They work independently of which model processes the request — LiteLLM calls the Bedrock ApplyGuardrail API as a separate HTTP call.

**Why this priority**: Adds a safety layer but is not required for basic proxy operation. Valuable for operators sharing access with teams or wanting compliance controls. Most complex feature of the four.

**Independent Test**: Can be tested by creating a guardrail in Terraform, configuring it in LiteLLM, and sending a request containing blocked content — verifying the proxy returns an appropriate error.

**Acceptance Scenarios**:

1. **Given** a Bedrock Guardrail is created with a content filter blocking violence, **When** a client sends a request with violent content, **Then** the proxy returns HTTP 400 with an error indicating the guardrail policy was violated
2. **Given** a guardrail with PII masking is configured with `mask_request_content: true`, **When** a client sends a message containing an email address, **Then** the email is masked before the request reaches the model
3. **Given** a guardrail is configured with `default_on: true`, **When** any client sends any request, **Then** the guardrail runs automatically without the client needing to opt in
4. **Given** a guardrail is configured on a specific model only, **When** a client sends a request to a different model, **Then** the guardrail does not run
5. **Given** an operator has not configured any guardrails, **When** any client sends any request, **Then** behavior is identical to today — no guardrail overhead

---

### Edge Cases

- What happens when a model hasn't been enabled in the Bedrock console? The proxy returns a Bedrock validation error. The operator must enable model access via the Bedrock console first. Unlike Stability AI and Luma Ray2, the new models (Llama 4, Nova 2 Lite, Mistral, GPT-OSS) do NOT require a Marketplace subscription — just standard Bedrock model access enablement
- What happens when a client sends `tool_choice` to Llama 4 models? LiteLLM's existing `drop_params: true` silently drops unsupported parameters — Llama 4 does not support `tool_choice`
- What happens when prompt caching TTL expires mid-conversation? The next request creates a new cache entry — cost increases for that single request, subsequent requests use the new cache
- What happens when a guardrail blocks content in `post_call` mode? The response is blocked after the model has already processed it — tokens are still consumed but the blocked response is returned to the client
- What happens when Nova 2 Lite receives `reasoning_effort: "high"` with explicit `temperature`? Bedrock rejects the combination — temperature/topP/topK cannot be used with `maxReasoningEffort: "high"`. The proxy returns the Bedrock error
- What happens when GPT-OSS structured output (`response_format`) is requested? LiteLLM falls back to synthetic tool injection because native constrained decoding is broken for GPT-OSS on Bedrock
- What happens when Mistral/GPT-OSS models are invoked but their region (eu-west-2) is unreachable? Standard Bedrock timeout/error behavior — no cross-region fallback since these models lack cross-region inference profiles
- What happens when `rockport.sh status` runs before new models are enabled in the Bedrock console? The models appear as unhealthy in the status output — this is correct behavior. The unhealthy display tells the operator exactly which models need Bedrock console enablement. No special filtering or suppression needed

## Clarifications

### Session 2026-03-22

- Q: Should the spec include a formal FR for CLI status health coverage of new models? → A: Yes — formal FR-025 requiring all new chat models appear healthy in `rockport.sh status`, with fallback to exclusion + manual probing if health probe fails
- Q: What should smoke tests verify for new models? → A: FR-026 — all 7 in model list (free) + 1 live streaming chat to `nova-2-lite` (cheapest with broad feature coverage)
- Q: Should status output handle unenabled models specially? → A: No — existing unhealthy display is correct; tells operator which models need Bedrock enablement

## Requirements *(mandatory)*

### Functional Requirements

**New Models:**
- **FR-001**: System MUST route `llama4-scout` requests to `bedrock/us.meta.llama4-scout-17b-instruct-v1:0` via US cross-region inference (us-east-1 region config, cross-region profile routes to available US region)
- **FR-002**: System MUST route `llama4-maverick` requests to `bedrock/us.meta.llama4-maverick-17b-instruct-v1:0` via US cross-region inference
- **FR-003**: System MUST route `nova-2-lite` requests to `bedrock/us.amazon.nova-2-lite-v1:0` via US cross-region inference (EU inference profiles not available for Nova 2 Lite)
- **FR-004**: System MUST route `mistral-large-3` requests to `bedrock/mistral.mistral-large-3-675b-instruct` in us-east-1 (not available in EU regions)
- **FR-005**: System MUST route `ministral-8b` requests to `bedrock/mistral.ministral-3-8b-instruct` in eu-west-2
- **FR-006**: System MUST route `gpt-oss-120b` requests to `bedrock/openai.gpt-oss-120b-1:0` in eu-west-2
- **FR-007**: System MUST route `gpt-oss-20b` requests to `bedrock/openai.gpt-oss-20b-1:0` in eu-west-2
- **FR-008**: System MUST enforce `--claude-only` key restrictions for all new models (non-Anthropic models return 403)
- **FR-009**: System MUST track spend for all new models via existing LiteLLM spend tracking at correct per-model rates
- **FR-010**: IAM policy MUST grant `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` for new model family patterns: `meta.llama4*`, `mistral.mistral-large-3*`, `mistral.ministral*`, `openai.gpt-oss*` in appropriate regions

**Prompt Caching:**
- **FR-011**: System MUST pass through `cache_control` blocks from client requests to Bedrock `cachePoint` blocks without additional proxy configuration
- **FR-012**: System MUST track cache read and cache write token costs separately using LiteLLM's built-in cost tracking at the model-specific cache rates
- **FR-013**: System SHOULD provide optional `cache_control_injection_points` configuration for models where server-side cache injection is desired for non-cache-aware clients
- **FR-014**: System MUST support 1-hour TTL for Claude 4.5+ models when `cache_control` includes `ttl: "1h"`

**Extended Thinking:**
- **FR-015**: System MUST support `reasoning_effort` parameter for Claude 4.6 models (mapped to adaptive thinking), Nova 2 Lite (mapped to `reasoningConfig`), and GPT-OSS models (passed through directly)
- **FR-016**: System MUST silently drop `reasoning_effort` for models that do not support it (via existing `drop_params: true`)
- **FR-017**: System SHOULD set `modify_params: true` in LiteLLM settings to handle multi-turn tool-use conversations with thinking gracefully (avoids "Expected thinking but found tool_use" errors)

**Guardrails:**
- **FR-018**: System MUST support optional Bedrock Guardrails defined as an infrastructure resource with content filtering policies
- **FR-019**: System MUST support guardrail configuration in LiteLLM with `mode: pre_call`, `post_call`, or `during_call`
- **FR-020**: System MUST support `default_on: true` for global guardrail application
- **FR-021**: System MUST support per-model guardrail assignment via model configuration
- **FR-022**: System MUST support PII masking via `mask_request_content` and `mask_response_content` options
- **FR-023**: IAM policy MUST grant `bedrock:ApplyGuardrail` permission on the guardrail resource
- **FR-024**: Guardrails MUST be entirely optional — no guardrail configuration means zero overhead and identical behavior to current system

**CLI & Tooling:**
- **FR-025**: All new chat models MUST appear as healthy in `rockport.sh status` output via LiteLLM's built-in health probe. If any new model rejects the health probe's `max_tokens` parameter (as image models do), the CLI MUST add the model to the exclusion pattern and implement manual probing — following the existing pattern in `cmd_status()` (lines 695-764 of `scripts/rockport.sh`)
- **FR-026**: Smoke tests (`tests/smoke-test.sh`) MUST verify all 7 new model names appear in `GET /v1/models` response (free — no Bedrock invocation) and MUST send 1 live streaming chat completion to `nova-2-lite` to confirm end-to-end connectivity (~$0.001 per run). Follow existing explicit bash error handling per constitution

### Key Entities

- **Model Entry**: A model definition in the proxy config mapping a client-facing name to a Bedrock model ID, region, and optional settings
- **Bedrock Guardrail**: An infrastructure resource defining content filtering policies (content, topic, word, PII, grounding), referenced by ID and version in proxy config
- **Cache Point**: A marker in the request indicating content eligible for caching, translated from client `cache_control` format to Bedrock `cachePoint` blocks by the proxy
- **Reasoning Config**: Model-specific parameters controlling extended thinking behavior — varies by model family (adaptive for Claude 4.6, intensity levels for Nova 2, pass-through for GPT-OSS)

## Assumptions

- LiteLLM version running on the instance is from after January 2026 (includes fix for Nova 2 `textGenerationConfig` bug, PR #18250)
- Llama 4 models use `us.` cross-region inference profiles (US-only). Mistral, GPT-OSS, and Nova 2 Lite are available in eu-west-2 directly
- Mistral Large 3, Ministral, and GPT-OSS models require one-time model access enablement in the Bedrock console (standard access request, NOT a Marketplace subscription — unlike Stability AI and Luma Ray2)
- Prompt caching is enabled by default on Bedrock for supported models — no AWS-side opt-in needed
- The existing `drop_params: true` setting handles unsupported parameters gracefully across all new models
- Nova 2 Lite is GA (not preview); Nova 2 Pro remains preview and is excluded from this spec

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 7 new models respond successfully to basic chat completion requests through the proxy
- **SC-002**: Cached requests to Claude models show at least 75% reduction in input token cost compared to uncached requests (verified via spend tracking)
- **SC-003**: Extended thinking produces visible reasoning content in responses for Claude 4.6, Nova 2 Lite, and GPT-OSS 120B when `reasoning_effort` is set
- **SC-004**: Guardrails block prohibited content and return a clear error to the client when configured
- **SC-005**: All existing models (Claude, DeepSeek, Qwen, Kimi, Nova v1, image models, video models) continue to work identically after the expansion
- **SC-006**: Smoke tests pass for all new models confirming basic request/response flow
- **SC-007**: Spend tracking accurately reports costs for all new models and reflects cache-read discounts for cached requests
