#!/bin/bash
set -euo pipefail

BASE_URL="${1:?Usage: smoke-test.sh <base-url> <valid-key>}"
VALID_KEY="${2:?Usage: smoke-test.sh <base-url> <valid-key>}"
PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"
  if [[ "$result" == "0" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Rockport Smoke Tests ==="
echo "Target: $BASE_URL"
echo

# 1. Health endpoint (requires auth in LiteLLM with master key enabled)
echo "1. Health check"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10)
[[ "$HTTP_CODE" == "200" ]]; check "GET /health returns 200" "$?"

HEALTH_BODY=$(curl -s "$BASE_URL/health" -H "Authorization: Bearer $VALID_KEY" --max-time 10)
echo "$HEALTH_BODY" | grep -q "healthy"; check "Health response contains 'healthy'" "$?"

# 2. Auth rejection with invalid key
echo "2. Auth rejection"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer sk-invalid-key-12345" --max-time 10)
[[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; check "Invalid key rejected (401/403)" "$?"

# 3. Auth success with valid key
echo "3. Auth success"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10)
[[ "$HTTP_CODE" == "200" ]]; check "Valid key accepted (200)" "$?"

# 4. Model list contains expected aliases
echo "4. Model list"
MODELS=$(curl -s "$BASE_URL/v1/models" -H "Authorization: Bearer $VALID_KEY" --max-time 10)
echo "$MODELS" | grep -q "claude-sonnet-4-6"; check "Model list contains claude-sonnet-4-6" "$?"
echo "$MODELS" | grep -q "nova-pro"; check "Model list contains nova-pro" "$?"

# 5. Streamed response
echo "5. Streaming"
STREAM_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}],"stream":true}' \
  --max-time 30 2>/dev/null)
echo "$STREAM_RESPONSE" | grep -q "data:"; check "Streaming response received" "$?"

# 6. Image generation (text-to-image)
echo "6. Image generation"
IMAGE_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/images/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-canvas","prompt":"a solid red circle on white background","n":1,"size":"512x512"}' \
  --max-time 60 2>/dev/null)
echo "$IMAGE_RESPONSE" | grep -q "b64_json"; check "Image generation returns b64_json" "$?"

# 7. Image edits endpoint reachable (WAF allows /v1/images/edits)
echo "7. Image edits endpoint"
EDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{}' --max-time 10 2>/dev/null)
# 400/422 = reached LiteLLM (bad request but not WAF blocked); 403 = WAF blocked
[[ "$EDIT_CODE" != "403" ]]; check "Image edits endpoint not WAF-blocked (HTTP $EDIT_CODE)" "$?"

# 8. Model list contains image models
echo "8. Image models in model list"
echo "$MODELS" | grep -q "nova-canvas"; check "Model list contains nova-canvas" "$?"
echo "$MODELS" | grep -q "titan-image-v2"; check "Model list contains titan-image-v2" "$?"

# Summary
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
