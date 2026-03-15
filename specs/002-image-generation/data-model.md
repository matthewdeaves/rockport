# Data Model: Image Generation via Bedrock

No new data entities are introduced. This feature extends existing configuration and uses LiteLLM's built-in key model restrictions.

## Configuration Changes

### LiteLLM Config (`config/litellm-config.yaml`)

New model entries added to `model_list`:

| Alias | Bedrock Model ID | Region | Capabilities |
|-------|-----------------|--------|-------------|
| `nova-canvas` | `amazon.nova-canvas-v1:0` | us-west-2 | text-to-image, image-to-image, inpainting |
| `titan-image-v2` | `amazon.titan-image-generator-v2:0` | us-west-2 | text-to-image, image-to-image, inpainting |
| `sd3-large` | `stability.sd3-large-v1:0` | us-west-2 | text-to-image |

### Key Model Restrictions

LiteLLM's `/key/generate` API accepts an optional `models` array. When set, the key can only access those models.

**Claude Code keys** (created by `setup-claude` or `key create --claude-only`):
```json
{
  "models": [
    "claude-opus-4-6",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001",
    "claude-sonnet-4-5-20250929",
    "claude-opus-4-5-20251101"
  ]
}
```

**General keys** (created by `key create` without flags):
No `models` parameter — full access to all configured models (chat + image).

### Terraform Locals

`bedrock_regions` extended:
```hcl
bedrock_regions = distinct(concat(
  [var.region],
  ["eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2",
   "eu-north-1", "eu-south-1", "eu-south-2", "us-west-2"]
))
```

### WAF Allowlist

New path added:
```
/v1/images/generations
```
