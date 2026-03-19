# Quickstart: Complete Image Services

## Prerequisites

- Rockport deployed and healthy (`rockport.sh status`)
- API key with full model access (not --claude-only): `rockport.sh key create test-key`
- Stability AI Marketplace subscriptions activated (auto-activates on first invoke with `aws-marketplace:Subscribe` IAM permission)
- Cloudflare Access credentials (CF-Access-Client-Id, CF-Access-Client-Secret)

## Test New Sidecar Endpoints

Replace `$KEY`, `$CF_ID`, `$CF_SECRET`, `$URL` with your values. `$IMG_B64` is a base64-encoded PNG.

### Inpaint
```bash
curl -X POST "$URL/v1/images/inpaint" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\", \"prompt\": \"blue sky\", \"mask\": \"data:image/png;base64,$MASK_B64\"}"
```

### Erase Object
```bash
curl -X POST "$URL/v1/images/erase" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\", \"mask\": \"data:image/png;base64,$MASK_B64\"}"
```

### Creative Upscale
```bash
curl -X POST "$URL/v1/images/creative-upscale" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\", \"prompt\": \"detailed fantasy character\"}"
```

### Fast Upscale
```bash
curl -X POST "$URL/v1/images/fast-upscale" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\"}"
```

### Search & Recolor
```bash
curl -X POST "$URL/v1/images/search-recolor" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\", \"prompt\": \"bright red\", \"select_prompt\": \"the hat\"}"
```

### Stability Outpaint
```bash
curl -X POST "$URL/v1/images/stability-outpaint" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"image\": \"data:image/png;base64,$IMG_B64\", \"right\": 200, \"prompt\": \"forest background\"}"
```

## Test New LiteLLM Models

### Stable Image Ultra
```bash
curl -X POST "$URL/v1/images/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"model": "stable-image-ultra", "prompt": "A majestic mountain landscape"}'
```

### Stable Image Core
```bash
curl -X POST "$URL/v1/images/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"model": "stable-image-core", "prompt": "A simple sketch of a cat"}'
```

## Verify Spend Tracking

After running test calls:
```bash
./scripts/rockport.sh spend models
```
Should show entries for each new model name.

## Smoke Test

```bash
./tests/smoke-test.sh
```
All new endpoint tests should pass (routing verification with invalid input).
