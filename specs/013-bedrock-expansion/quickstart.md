# Quickstart: Rockport Bedrock Expansion

**Branch**: `013-bedrock-expansion`

## Prerequisites

- Rockport deployed and running (existing models working)
- LiteLLM version from after January 2026 (Nova 2 bug fix)
- AWS Bedrock model access enabled for: Llama 4 Scout, Llama 4 Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, GPT-OSS 120B, GPT-OSS 20B

## Quick Verification

After deploying this feature:

```bash
# 1. Check new models appear
./scripts/rockport.sh models

# 2. Test a new model
curl -s https://llm.matthewdeaves.com/v1/chat/completions \
  -H "Authorization: Bearer $ROCKPORT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "nova-2-lite", "messages": [{"role": "user", "content": "Hello"}]}'

# 3. Test extended thinking
curl -s https://llm.matthewdeaves.com/v1/chat/completions \
  -H "Authorization: Bearer $ROCKPORT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "nova-2-lite", "messages": [{"role": "user", "content": "What is 15 * 37?"}], "reasoning_effort": "high"}'

# 4. Verify prompt caching (check usage in response)
# Claude Code does this automatically — just use it normally and check spend

# 5. Check spend tracking
./scripts/rockport.sh spend models
```

## Files Changed

1. `config/litellm-config.yaml` — 7 new model entries + `modify_params: true` + optional guardrail config
2. `terraform/main.tf` — IAM policy updates for new model families
3. `terraform/guardrails.tf` — New file (optional Bedrock Guardrail resource)
4. `tests/smoke-test.sh` — Extended to cover new models
5. `CLAUDE.md` — Updated model list and notes
