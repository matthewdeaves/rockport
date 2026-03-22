# Contract: Model Routing

**Date**: 2026-03-22 | **Branch**: `013-bedrock-expansion`

## Interface

Rockport exposes the OpenAI-compatible `/v1/chat/completions` endpoint. Clients specify a model name; the proxy routes to the correct Bedrock model.

## New Model Names

These model names are added to the existing set. All use the same endpoint and request format.

| Client Model Name | Bedrock Model ID | Provider | Max Input | Max Output |
|------------------|-----------------|----------|-----------|------------|
| `llama4-scout` | `us.meta.llama4-scout-17b-instruct-v1:0` | bedrock_converse | 128K | 4,096 |
| `llama4-maverick` | `us.meta.llama4-maverick-17b-instruct-v1:0` | bedrock_converse | 128K | 4,096 |
| `nova-2-lite` | `eu.amazon.nova-2-lite-v1:0` | bedrock_converse | 1M | 64K |
| `mistral-large-3` | `mistral.mistral-large-3-675b-instruct` | bedrock_converse | 128K | 8,192 |
| `ministral-8b` | `mistral.ministral-3-8b-instruct` | bedrock_converse | 128K | 8,192 |
| `gpt-oss-120b` | `openai.gpt-oss-120b-1:0` | bedrock_converse | 128K | 128K |
| `gpt-oss-20b` | `openai.gpt-oss-20b-1:0` | bedrock_converse | 128K | 128K |

## Feature Support Matrix

| Feature | Llama 4 | Nova 2 Lite | Mistral L3 | Ministral | GPT-OSS |
|---------|---------|-------------|------------|-----------|---------|
| Streaming | yes | yes | yes | yes | yes |
| Vision (images) | yes | yes | no | no | no |
| Video input | no | yes | no | no | no |
| PDF input | no | yes | no | no | no |
| Function calling | yes | yes | yes | yes | yes |
| tool_choice | **no** | yes | yes | yes | yes |
| Reasoning | no | yes | no | no | yes |
| Prompt caching | no | yes | no | no | no |
| Structured output | no | yes | native | native | synthetic fallback |

## Parameters

### Extended Thinking (reasoning_effort)

Accepted values: `"low"`, `"medium"`, `"high"`

| Model | Behavior |
|-------|----------|
| Claude 4.6 | → `thinking: {type: "adaptive"}` |
| Nova 2 Lite | → `reasoningConfig: {type: "enabled", maxReasoningEffort: <value>}` |
| GPT-OSS | → pass-through as-is |
| All others | → silently dropped (`drop_params: true`) |

### Prompt Caching (cache_control)

Pass `cache_control: {"type": "ephemeral"}` on message content blocks. Optionally include `"ttl": "1h"` for Claude 4.5+ models.

Response usage includes:
- `cache_read_input_tokens`: Tokens served from cache
- `cache_creation_input_tokens`: Tokens written to cache

### Guardrails

Client can optionally pass `guardrails: ["<guardrail-name>"]` in request body to trigger a configured guardrail. If `default_on: true` is set, no client action needed.

Blocked response: HTTP 400 with `{"error": "Violated guardrail policy", "bedrock_guardrail_response": "..."}`
