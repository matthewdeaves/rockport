# Contract: Image Generation Endpoint

## Endpoint

`POST /v1/images/generations`

Proxied by LiteLLM — follows OpenAI image generation API spec.

## Request

```json
{
  "model": "nova-canvas",
  "prompt": "a lighthouse on a rocky coast at sunset",
  "n": 1,
  "size": "1024x1024"
}
```

**Headers**:
- `Authorization: Bearer sk-<key>` or `x-api-key: sk-<key>`
- `Content-Type: application/json`

## Response

```json
{
  "created": 1710500000,
  "data": [
    {
      "b64_json": "<base64-encoded-image>",
      "revised_prompt": "..."
    }
  ]
}
```

## Error Responses

- `401 Unauthorized` — Invalid or revoked key
- `403 Forbidden` — Key does not have access to the requested model
- `400 Bad Request` — Invalid parameters (unsupported size, etc.)
- `500 Internal Server Error` — Bedrock call failure

## SDK Usage

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.matthewdeaves.com/v1",
    api_key="sk-your-key"
)

# Text-to-image
response = client.images.generate(
    model="nova-canvas",
    prompt="a lighthouse on a rocky coast",
    n=1,
    size="1024x1024"
)
image_b64 = response.data[0].b64_json
```
