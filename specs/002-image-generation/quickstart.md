# Quickstart: Image Generation via Rockport

## Prerequisites

- Rockport deployed and healthy (`rockport status`)
- Image models enabled in AWS Bedrock console for us-west-2 (Nova Canvas, Titan Image Gen v2)
- A general-access API key (`rockport key create myapp`)

## Generate an Image (Python)

```bash
pip install openai
```

```python
from openai import OpenAI
import base64

client = OpenAI(
    base_url="https://llm.matthewdeaves.com/v1",
    api_key="sk-your-key"
)

response = client.images.generate(
    model="nova-canvas",
    prompt="a lighthouse on a rocky coast at sunset, watercolor style",
    n=1,
    size="1024x1024"
)

# Save the image
image_data = base64.b64decode(response.data[0].b64_json)
with open("lighthouse.png", "wb") as f:
    f.write(image_data)
```

## Generate an Image (curl)

```bash
curl https://llm.matthewdeaves.com/v1/images/generations \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nova-canvas",
    "prompt": "a lighthouse on a rocky coast",
    "n": 1,
    "size": "1024x1024"
  }' | jq -r '.data[0].b64_json' | base64 -d > image.png
```

## Available Image Models

| Alias | Best For |
|-------|---------|
| `nova-canvas` | General-purpose, inpainting, outpainting, background removal |
| `titan-image-v2` | Photorealistic, image variations, fine control |
| `sd3-large` | Artistic/creative, text rendering |

## Key Types

| Command | Access |
|---------|--------|
| `rockport key create myapp` | All models (chat + image) |
| `rockport key create claude --claude-only` | Anthropic models only |
| `rockport setup-claude` | Anthropic models only (auto-configured for Claude Code) |
