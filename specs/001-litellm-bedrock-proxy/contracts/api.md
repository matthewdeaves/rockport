# API Contracts: LiteLLM Bedrock Proxy

**Date**: 2026-03-13
**Feature**: 001-litellm-bedrock-proxy

## Overview

All endpoints are provided by LiteLLM proxy — no custom code.
Rockport exposes LiteLLM at `https://llm.matthewdeaves.com`
via Cloudflare Tunnel.

## User-Facing Endpoints (Anthropic Format)

### POST /v1/messages

Claude Code's primary endpoint. Anthropic Messages API format.

**Headers**:
```
x-api-key: sk-<virtual-key>
Content-Type: application/json
anthropic-version: 2023-06-01
```

**Request body** (example):
```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 1024,
  "messages": [
    {"role": "user", "content": "Hello"}
  ],
  "stream": true
}
```

**Response** (streaming SSE):
```
event: message_start
data: {"type":"message_start","message":{...}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

event: message_stop
data: {"type":"message_stop"}
```

**Auth failure**: 401 with error message before any Bedrock call.

## Admin Endpoints (LiteLLM Built-in)

All admin endpoints require `Authorization: Bearer <master-key>`.

### POST /key/generate

Create a new virtual API key.

```bash
curl -X POST https://llm.matthewdeaves.com/key/generate \
  -H "Authorization: Bearer sk-<master-key>" \
  -H "Content-Type: application/json" \
  -d '{"key_name": "matt-dev"}'
```

**Response**: `{"key": "sk-...", "key_name": "matt-dev", ...}`

### POST /key/delete

Revoke one or more keys.

```bash
curl -X POST https://llm.matthewdeaves.com/key/delete \
  -H "Authorization: Bearer sk-<master-key>" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-revoke"]}'
```

### POST /key/info

Get key details and spend.

```bash
curl -X POST https://llm.matthewdeaves.com/key/info \
  -H "Authorization: Bearer sk-<master-key>" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-<virtual-key>"}'
```

### GET /key/list

List all virtual keys with spend.

### GET /global/spend

Global spend summary across all keys.

### GET /health

Health check (no auth required).

**Response**: `{"status": "healthy", "healthy_endpoints": [...], "unhealthy_endpoints": [...]}`

### GET /v1/models

List available models (requires auth).

## Model Aliases

Defined in `config/litellm-config.yaml`. Current mappings:

| Alias (what client sends) | Bedrock Model ID |
|---------------------------|------------------|
| `claude-opus-4-6` | `bedrock/eu.anthropic.claude-opus-4-6-v1` |
| `claude-sonnet-4-6` | `bedrock/eu.anthropic.claude-sonnet-4-6` |
| `claude-haiku-4-5-20251001` | `bedrock/eu.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `claude-sonnet-4-5-20250929` (alias) | `bedrock/eu.anthropic.claude-sonnet-4-6` |
| `claude-opus-4-5-20251101` (alias) | `bedrock/eu.anthropic.claude-opus-4-6-v1` |
| `deepseek-v3.2` | `bedrock/deepseek.v3.2` |
| `qwen3-coder-480b` | `bedrock/qwen.qwen3-coder-480b-a35b-v1:0` |
| `kimi-k2.5` | `bedrock/moonshotai.kimi-k2.5` |
| `nova-pro` | `bedrock/amazon.nova-pro-v1:0` |
| `nova-lite` | `bedrock/amazon.nova-lite-v1:0` |
| `nova-micro` | `bedrock/amazon.nova-micro-v1:0` |

## CLI Contract (rockport.sh)

```
rockport status              → GET /health (formatted)
rockport models              → GET /v1/models (formatted)
rockport key create <name>   → POST /key/generate
rockport key list            → GET /key/list
rockport key info <key>      → POST /key/info
rockport key revoke <key>    → POST /key/delete
rockport spend               → GET /global/spend
rockport config push         → SSM: write config + restart service
rockport logs                → SSM: journalctl -u litellm -f
rockport deploy              → terraform init + apply
rockport destroy             → terraform destroy (with confirmation)
rockport upgrade             → SSM: systemctl restart litellm
```
