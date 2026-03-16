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

# 7. Image edits endpoint blocked (not supported for Bedrock models)
echo "7. Image edits blocked"
EDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{}' --max-time 10 2>/dev/null)
[[ "$EDIT_CODE" == "403" ]]; check "Image edits endpoint WAF-blocked (HTTP $EDIT_CODE)" "$?"

# 8. Model list contains image models
echo "8. Image models in model list"
echo "$MODELS" | grep -q "nova-canvas"; check "Model list contains nova-canvas" "$?"
echo "$MODELS" | grep -q "titan-image-v2"; check "Model list contains titan-image-v2" "$?"

# 9. Video sidecar health
echo "9. Video sidecar health"
VIDEO_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/health" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10 2>/dev/null)
[[ "$VIDEO_HEALTH_CODE" == "200" ]]; check "Video health returns 200 (HTTP $VIDEO_HEALTH_CODE)" "$?"

# 10. Video generation submit
echo "10. Video generation submit"
VIDEO_SUBMIT=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a solid red circle on white background","duration":6}' \
  --max-time 30 2>/dev/null)
VIDEO_SUBMIT_CODE=$(echo "$VIDEO_SUBMIT" | tail -1)
VIDEO_SUBMIT_BODY=$(echo "$VIDEO_SUBMIT" | sed '$d')
[[ "$VIDEO_SUBMIT_CODE" == "202" ]]; check "Video submit returns 202 (HTTP $VIDEO_SUBMIT_CODE)" "$?"
VIDEO_JOB_ID=$(echo "$VIDEO_SUBMIT_BODY" | jq -r '.id // empty' 2>/dev/null)
[[ -n "$VIDEO_JOB_ID" ]]; check "Video submit returns job ID" "$?"

# 11. Video generation poll
echo "11. Video generation poll"
if [[ -n "$VIDEO_JOB_ID" ]]; then
  VIDEO_STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/generations/$VIDEO_JOB_ID" \
    -H "Authorization: Bearer $VALID_KEY" --max-time 10 2>/dev/null)
  [[ "$VIDEO_STATUS_CODE" == "200" ]]; check "Video status returns 200 (HTTP $VIDEO_STATUS_CODE)" "$?"
else
  check "Video status returns 200 (skipped, no job ID)" "1"
fi

# 12. Video generation list
echo "12. Video generation list"
VIDEO_LIST_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10 2>/dev/null)
[[ "$VIDEO_LIST_CODE" == "200" ]]; check "Video list returns 200 (HTTP $VIDEO_LIST_CODE)" "$?"

# 13. Video auth rejection
echo "13. Video auth rejection"
VIDEO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer sk-invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"test"}' --max-time 10 2>/dev/null)
[[ "$VIDEO_AUTH_CODE" == "401" || "$VIDEO_AUTH_CODE" == "403" ]]; check "Video invalid key rejected (HTTP $VIDEO_AUTH_CODE)" "$?"

# 14. WAF blocks non-allowlisted video paths
echo "14. Video WAF block"
VIDEO_WAF_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/somethingelse" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10 2>/dev/null)
# /v1/videos/* is allowed by WAF, so this should reach the sidecar (404, not 403)
[[ "$VIDEO_WAF_CODE" != "403" ]]; check "Video paths not WAF-blocked (HTTP $VIDEO_WAF_CODE)" "$?"

# 15. Video model selection — explicit nova-reel
echo "15. Video model selection"
VIDEO_MODEL_SUBMIT=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-reel","prompt":"a blue sky","duration":6}' \
  --max-time 30 2>/dev/null)
VIDEO_MODEL_CODE=$(echo "$VIDEO_MODEL_SUBMIT" | tail -1)
VIDEO_MODEL_BODY=$(echo "$VIDEO_MODEL_SUBMIT" | sed '$d')
[[ "$VIDEO_MODEL_CODE" == "202" ]]; check "Explicit nova-reel model returns 202 (HTTP $VIDEO_MODEL_CODE)" "$?"
echo "$VIDEO_MODEL_BODY" | jq -e '.model == "nova-reel"' >/dev/null 2>&1; check "Response includes model field" "$?"

# 16. Video unknown model rejection
echo "16. Video unknown model rejection"
VIDEO_BAD_MODEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nonexistent","prompt":"test","duration":6}' \
  --max-time 10 2>/dev/null)
[[ "$VIDEO_BAD_MODEL_CODE" == "400" ]]; check "Unknown video model rejected (HTTP $VIDEO_BAD_MODEL_CODE)" "$?"

# 17. Video health shows per-model status
echo "17. Video per-model health"
VIDEO_HEALTH_BODY=$(curl -s "$BASE_URL/v1/videos/health" \
  -H "Authorization: Bearer $VALID_KEY" --max-time 10 2>/dev/null)
echo "$VIDEO_HEALTH_BODY" | jq -e '.models["nova-reel"]' >/dev/null 2>&1; check "Health includes nova-reel model status" "$?"
echo "$VIDEO_HEALTH_BODY" | jq -e '.models["luma-ray2"]' >/dev/null 2>&1; check "Health includes luma-ray2 model status" "$?"

# Summary
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
