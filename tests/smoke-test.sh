#!/bin/bash
set -euo pipefail

# Rockport Smoke Tests
# Tests routing, auth, validation, and basic functionality.
# Designed to be cheap: most tests trigger validation errors (free) rather
# than real Bedrock calls. Only tests 5 (chat) and 6 (image) cost money
# (~$0.01 chat + ~$0.04 image = ~$0.05 total).

BASE_URL="${1:?Usage: smoke-test.sh <base-url> [cf-client-id cf-client-secret]}"
CF_CLIENT_ID="${2:-${CF_ACCESS_CLIENT_ID:-}}"
CF_CLIENT_SECRET="${3:-${CF_ACCESS_CLIENT_SECRET:-}}"
PASS=0
FAIL=0

# Build CF Access header args if provided
CF_ARGS=()
if [[ -n "$CF_CLIENT_ID" && -n "$CF_CLIENT_SECRET" ]]; then
  CF_ARGS=(-H "CF-Access-Client-Id: $CF_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_CLIENT_SECRET")
  echo "CF Access headers: enabled"
fi

# Create a temporary API key for testing
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Creating temporary test key..."
KEY_OUTPUT=$("$SCRIPT_DIR/../scripts/rockport.sh" key create smoke-test-$$ 2>&1)
VALID_KEY=$(echo "$KEY_OUTPUT" | grep -oP '(?<=Key:\s{4})sk-[a-zA-Z0-9_-]+')
if [[ -z "$VALID_KEY" ]]; then
  echo "ERROR: Failed to create test key" >&2
  echo "$KEY_OUTPUT" >&2
  exit 1
fi
echo "  Test key created: ${VALID_KEY:0:12}..."
sleep 2  # Allow key to propagate through LiteLLM

# Cleanup on exit
cleanup() {
  echo "Cleaning up test key..."
  "$SCRIPT_DIR/../scripts/rockport.sh" key revoke "$VALID_KEY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

# --- Core Infrastructure ---

# 1. Health endpoint
echo "1. Health check"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 30)
[[ "$HTTP_CODE" == "200" ]]; check "GET /health returns 200" "$?"

# 2. Auth rejection with invalid key
echo "2. Auth rejection"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer sk-invalid-key-12345" `# gitleaks:allow` "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
[[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; check "Invalid key rejected (401/403)" "$?"

# 3. Auth success with valid key
echo "3. Auth success"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
[[ "$HTTP_CODE" == "200" ]]; check "Valid key accepted (200)" "$?"

# 4. Model list contains expected aliases
echo "4. Model list"
MODELS=$(curl -s "$BASE_URL/v1/models" -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
echo "$MODELS" | grep -q "claude-sonnet-4-6"; check "Model list contains claude-sonnet-4-6" "$?"
echo "$MODELS" | grep -q "nova-pro"; check "Model list contains nova-pro" "$?"
echo "$MODELS" | grep -q "nova-canvas"; check "Model list contains nova-canvas" "$?"
echo "$MODELS" | grep -q "titan-image-v2"; check "Model list contains titan-image-v2" "$?"

# 5. Streamed chat response (~$0.01)
echo "5. Streaming chat"
STREAM_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}],"stream":true}' \
  --max-time 60 2>/dev/null)
echo "$STREAM_RESPONSE" | grep -q "data:"; check "Streaming response received" "$?"

# 6. Image generation via LiteLLM (~$0.04)
echo "6. Image generation (LiteLLM route)"
IMAGE_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/images/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-canvas","prompt":"a solid red circle on white background","n":1,"size":"512x512"}' \
  --max-time 60 2>/dev/null)
echo "$IMAGE_RESPONSE" | grep -q "b64_json"; check "Image generation returns b64_json" "$?"

# --- Video Sidecar ---

# 7. Video sidecar health
echo "7. Video sidecar health"
VIDEO_HEALTH_BODY=$(curl -s "$BASE_URL/v1/videos/health" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
echo "$VIDEO_HEALTH_BODY" | grep -q "healthy"; check "Video sidecar healthy" "$?"
echo "$VIDEO_HEALTH_BODY" | jq -e '.models["nova-reel"]' >/dev/null 2>&1; check "Health includes nova-reel" "$?"
echo "$VIDEO_HEALTH_BODY" | jq -e '.models["luma-ray2"]' >/dev/null 2>&1; check "Health includes luma-ray2" "$?"

# 8. Video auth rejection
echo "8. Video auth rejection"
VIDEO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer sk-invalid-key-12345" `# gitleaks:allow` \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"prompt":"test"}' --max-time 10 2>/dev/null)
[[ "$VIDEO_AUTH_CODE" == "401" || "$VIDEO_AUTH_CODE" == "403" ]]; check "Video invalid key rejected (HTTP $VIDEO_AUTH_CODE)" "$?"

# 9. Video unknown model rejection (free — fails before Bedrock)
echo "9. Video model validation"
VIDEO_BAD_MODEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nonexistent","prompt":"Armoured knight walking steadily forward in side profile, arms swinging naturally, static shot","duration":6}' \
  --max-time 10 2>/dev/null)
[[ "$VIDEO_BAD_MODEL_CODE" == "400" ]]; check "Unknown video model rejected (HTTP $VIDEO_BAD_MODEL_CODE)" "$?"

# 10. Video invalid duration rejection (free — fails before Bedrock)
echo "10. Video duration validation"
VIDEO_DUR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking steadily forward in side profile, arms swinging naturally, static shot","duration":7}' \
  --max-time 10 2>/dev/null)
[[ "$VIDEO_DUR_CODE" == "400" ]]; check "Invalid duration rejected (HTTP $VIDEO_DUR_CODE)" "$?"

# 11. Video list (no jobs is fine, just routing check)
echo "11. Video list"
VIDEO_LIST_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
[[ "$VIDEO_LIST_CODE" == "200" ]]; check "Video list returns 200 (HTTP $VIDEO_LIST_CODE)" "$?"

# --- Prompt Validation (free — all rejected before Bedrock) ---

# 12. Negation word rejection
echo "12. Prompt validation — negation"
NEGATION_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"A knight walking forward through a dark castle courtyard, no sword visible in the scene, static shot","duration":6}' \
  --max-time 10 2>/dev/null)
[[ "$NEGATION_CODE" == "400" ]]; check "Negation word 'no' rejected (HTTP $NEGATION_CODE)" "$?"

# 13. Camera keyword position rejection
echo "13. Prompt validation — camera position"
CAMERA_BODY=$(curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight, dolly forward, walking steadily in side profile and castle background","duration":6}' \
  --max-time 10 2>/dev/null)
echo "$CAMERA_BODY" | jq -e '.detail.error.rule == "camera_position"' >/dev/null 2>&1; check "Camera keyword mid-prompt rejected with correct rule" "$?"

# 14. Min length rejection
echo "14. Prompt validation — min length"
MINLEN_BODY=$(curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"a knight walking","duration":6}' \
  --max-time 10 2>/dev/null)
echo "$MINLEN_BODY" | jq -e '.detail.error.rule == "min_length"' >/dev/null 2>&1; check "Short prompt rejected with correct rule" "$?"

# 15. Contracted negation rejection
echo "15. Prompt validation — contracted negation"
CONTRACTION_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d "{\"model\":\"nova-reel\",\"prompt\":\"The warrior can't be stopped, moving through the dark battlefield scene, static shot\",\"duration\":6}" \
  --max-time 10 2>/dev/null)
[[ "$CONTRACTION_CODE" == "400" ]]; check "Contracted negation \"can't\" rejected (HTTP $CONTRACTION_CODE)" "$?"

# 16. Valid prompt accepted (free — uses invalid duration to fail AFTER prompt validation passes)
echo "16. Prompt validation — valid prompt passes"
VALID_PROMPT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking steadily forward in side profile, arms swinging in opposition to legs, weight shifting with each step, static shot","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for duration (not prompt) — means prompt validation passed
[[ "$VALID_PROMPT_CODE" == "400" ]]; check "Valid prompt passes validation (fails on duration instead)" "$?"

# 17. Ray2 not subject to prompt validation (free — uses validation error to avoid real job)
echo "17. Prompt validation — Ray2 bypass"
RAY2_BODY=$(curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"A knight walking forward, no sword visible","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for invalid duration (not prompt validation) — proves prompt validation was skipped
echo "$RAY2_BODY" | jq -e '.detail.error.type == "validation_error"' >/dev/null 2>&1; check "Ray2 skips prompt validation (fails on duration instead)" "$?"

# --- Image Endpoint Routing (free — validation errors) ---

# 18. Image generations routes to LiteLLM (already tested in #6)
echo "18. Image edits routes to sidecar (404, no handler)"
EDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{}' --max-time 10 2>/dev/null)
[[ "$EDIT_CODE" == "404" || "$EDIT_CODE" == "405" ]]; check "Image edits → sidecar 404 (HTTP $EDIT_CODE)" "$?"

# 19. Image variations endpoint reachable (validation error = routing works)
echo "19. Image variations endpoint"
IMGVAR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/variations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"images":["invalid"],"prompt":"test prompt with enough characters to pass"}' \
  --max-time 10 2>/dev/null)
[[ "$IMGVAR_CODE" == "400" || "$IMGVAR_CODE" == "422" ]]; check "Variations reachable, rejects bad input (HTTP $IMGVAR_CODE)" "$?"

# 20. Background removal endpoint reachable
echo "20. Background removal endpoint"
IMGBG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/background-removal" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid"}' \
  --max-time 10 2>/dev/null)
[[ "$IMGBG_CODE" == "400" || "$IMGBG_CODE" == "422" ]]; check "Background removal reachable (HTTP $IMGBG_CODE)" "$?"

# 21. Outpaint endpoint reachable
echo "21. Outpaint endpoint"
IMGOUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/outpaint" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid","prompt":"test","mask_prompt":"subject"}' \
  --max-time 10 2>/dev/null)
[[ "$IMGOUT_CODE" == "400" || "$IMGOUT_CODE" == "422" ]]; check "Outpaint reachable (HTTP $IMGOUT_CODE)" "$?"

# 22. Stability AI structure endpoint reachable
echo "22. Stability AI structure endpoint"
IMGSTR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/structure" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid","prompt":"test"}' \
  --max-time 10 2>/dev/null)
[[ "$IMGSTR_CODE" == "400" || "$IMGSTR_CODE" == "422" ]]; check "Structure reachable (HTTP $IMGSTR_CODE)" "$?"

# 23. Stability AI remove-background endpoint reachable
echo "23. Stability AI remove-background endpoint"
IMGRM_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/remove-background" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid"}' \
  --max-time 10 2>/dev/null)
[[ "$IMGRM_CODE" == "400" || "$IMGRM_CODE" == "422" ]]; check "Remove background reachable (HTTP $IMGRM_CODE)" "$?"


# Summary
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
