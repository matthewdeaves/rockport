# Quickstart: Verify Stability AI Migration

**Date**: 2026-03-19
**Feature**: 010-migrate-stability-to-litellm

## Prerequisites

- Deployed Rockport instance with updated config
- Valid API key (not `--claude-only`)
- CF Access credentials (if Cloudflare Access is enabled)

## 1. Verify Models Are Registered

```bash
./scripts/rockport.sh models | grep stability
```

Expected: All 13 `stability-*` models listed.

## 2. Test a Stability AI Operation via LiteLLM

```bash
# Test inpaint via /v1/images/edits (multipart form)
curl -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $API_KEY" \
  -F "model=stability-remove-background" \
  -F "image=@test-image.png" \
  --max-time 60
```

Expected: Returns JSON with `data[0].b64_json` containing the processed image.

## 3. Test Nova Canvas Still Works via Sidecar

```bash
# Test variations endpoint (still on sidecar)
curl -X POST "$BASE_URL/v1/images/variations" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"images":["data:image/png;base64,..."],"prompt":"test variation"}' \
  --max-time 60
```

Expected: Returns image variation via sidecar.

## 4. Verify Old Sidecar Paths Return 404

```bash
curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/structure" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"image":"invalid","prompt":"test"}'
```

Expected: `404` (endpoint removed from sidecar).

## 5. Run Full Smoke Tests

```bash
./tests/smoke-test.sh "$BASE_URL" "$CF_CLIENT_ID" "$CF_CLIENT_SECRET"
```

Expected: All tests pass.

## 6. Verify Spend Tracking

```bash
./scripts/rockport.sh spend models
```

Expected: Stability AI image operations appear in spend breakdown after use.
