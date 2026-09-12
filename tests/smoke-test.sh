#!/usr/bin/env bash

die() { echo "ERROR: $*" >&2; exit 1; }

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
INVALID_KEY="sk-not-a-real-key"

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
[[ -n "$VALID_KEY" ]] || die "Failed to create test key. Output: $KEY_OUTPUT"
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
  shift
  if "$@"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: check if value is one of the expected codes
check_code() {
  local name="$1" actual="$2"
  shift 2
  local expected
  for expected in "$@"; do
    if [[ "$actual" == "$expected" ]]; then
      echo "  PASS: $name"
      PASS=$((PASS + 1))
      return
    fi
  done
  echo "  FAIL: $name"
  FAIL=$((FAIL + 1))
}

echo "=== Rockport Smoke Tests ==="
echo "Target: $BASE_URL"
echo

# --- Core Infrastructure ---

# 1. Health endpoint
echo "1. Health check"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 30)
check_code "GET /health returns 200" "$HTTP_CODE" "200"

# 2. Auth rejection with invalid key
echo "2. Auth rejection"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer $INVALID_KEY" `# gitleaks:allow` "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
check_code "Invalid key rejected (401/403)" "$HTTP_CODE" "401" "403"

# 3. Auth success with valid key
echo "3. Auth success"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
check_code "Valid key accepted (200)" "$HTTP_CODE" "200"

# 4. Model list contains expected aliases
echo "4. Model list"
MODELS=$(curl -s "$BASE_URL/v1/models" -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10)
check "Model list contains claude-opus-5" grep -q "claude-opus-5" <<< "$MODELS"
check "Model list contains claude-sonnet-5" grep -q "claude-sonnet-5" <<< "$MODELS"
check "Model list contains claude-sonnet-4-6" grep -q "claude-sonnet-4-6" <<< "$MODELS"
check "Model list contains nova-pro" grep -q "nova-pro" <<< "$MODELS"
check "Model list contains llama4-scout" grep -q "llama4-scout" <<< "$MODELS"
check "Model list contains llama4-maverick" grep -q "llama4-maverick" <<< "$MODELS"
check "Model list contains nova-2-lite" grep -q "nova-2-lite" <<< "$MODELS"
check "Model list contains mistral-large-3" grep -q "mistral-large-3" <<< "$MODELS"
check "Model list contains ministral-8b" grep -q "ministral-8b" <<< "$MODELS"
check "Model list contains gpt-oss-120b" grep -q "gpt-oss-120b" <<< "$MODELS"
check "Model list contains gpt-oss-20b" grep -q "gpt-oss-20b" <<< "$MODELS"

# 5. Streamed chat response (~$0.01)
echo "5. Streaming chat"
STREAM_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"claude-sonnet-5","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}],"stream":true}' \
  --max-time 60 2>/dev/null)
check "Streaming response received" grep -q "data:" <<< "$STREAM_RESPONSE"

# 5b. Nova 2 Lite streaming chat (~$0.001)
echo "5b. Streaming chat (nova-2-lite)"
NOVA2_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-2-lite","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}],"stream":true}' \
  --max-time 60 2>/dev/null)
check "Nova 2 Lite streaming response received" grep -q "data:" <<< "$NOVA2_RESPONSE"

# 6. Image generation via LiteLLM (~$0.04, Stable Image Core is the cheapest text-to-image model)
echo "6. Image generation (LiteLLM route)"
IMAGE_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/images/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"stable-image-core","prompt":"a solid red circle on white background","n":1}' \
  --max-time 60 2>/dev/null)
check "Image generation returns b64_json" grep -q "b64_json" <<< "$IMAGE_RESPONSE"

# --- Video Sidecar ---

# 7. Video sidecar health
echo "7. Video sidecar health"
VIDEO_HEALTH_BODY=$(curl -s "$BASE_URL/v1/videos/health" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
check "Video sidecar healthy" grep -q "healthy" <<< "$VIDEO_HEALTH_BODY"
check "Health includes luma-ray2" jq -e '.models["luma-ray2"]' <<< "$VIDEO_HEALTH_BODY"

# 8. Video auth rejection
echo "8. Video auth rejection"
VIDEO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $INVALID_KEY" `# gitleaks:allow` \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"prompt":"test"}' --max-time 10 2>/dev/null)
check_code "Video invalid key rejected (HTTP $VIDEO_AUTH_CODE)" "$VIDEO_AUTH_CODE" "401" "403"

# 9. Video unknown model rejection (free — fails before Bedrock)
echo "9. Video model validation"
VIDEO_BAD_MODEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nonexistent","prompt":"Armoured knight walking steadily forward","duration":5}' \
  --max-time 10 2>/dev/null)
check_code "Unknown video model rejected (HTTP $VIDEO_BAD_MODEL_CODE)" "$VIDEO_BAD_MODEL_CODE" "400"

# 10. Video invalid duration rejection (free — fails before Bedrock)
echo "10. Video duration validation"
VIDEO_DUR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"Armoured knight walking steadily forward","duration":7}' \
  --max-time 10 2>/dev/null)
check_code "Invalid duration rejected (HTTP $VIDEO_DUR_CODE)" "$VIDEO_DUR_CODE" "400"

# 11. Video list (no jobs is fine, just routing check)
echo "11. Video list"
VIDEO_LIST_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
check_code "Video list returns 200 (HTTP $VIDEO_LIST_CODE)" "$VIDEO_LIST_CODE" "200"

# --- Ray2 parameter validation (free — all rejected before Bedrock) ---

# 12. Invalid resolution rejected
echo "12. Ray2 resolution validation"
RES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"A knight walking forward","duration":5,"resolution":"1080p"}' \
  --max-time 10 2>/dev/null)
check_code "Invalid resolution rejected (HTTP $RES_CODE)" "$RES_CODE" "400"

# 13. Invalid aspect ratio rejected
echo "13. Ray2 aspect ratio validation"
AR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"A knight walking forward","duration":5,"aspect_ratio":"2:1"}' \
  --max-time 10 2>/dev/null)
check_code "Invalid aspect ratio rejected (HTTP $AR_CODE)" "$AR_CODE" "400"

# 14. end_image without start image rejected
echo "14. Ray2 end_image requires image"
ENDIMG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"A knight walking forward","duration":5,"end_image":"data:image/png;base64,AAAA"}' \
  --max-time 10 2>/dev/null)
check_code "end_image without image rejected (HTTP $ENDIMG_CODE)" "$ENDIMG_CODE" "400"

# 15. Default model is luma-ray2 (omit model; invalid duration proves it resolved to Ray2's 5/9s rule)
echo "15. Default video model"
DEFAULT_BODY=$(curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"prompt":"A knight walking forward","duration":7}' \
  --max-time 10 2>/dev/null)
check "Default model resolves to luma-ray2" grep -q "luma-ray2" <<< "$DEFAULT_BODY"

# --- Image Endpoint Routing (free — validation errors) ---

# 16. Image edits routes to LiteLLM (Stability AI via /v1/images/edits)
echo "16. Image edits routes to LiteLLM"
EDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -F "model=stability-remove-background" \
  -F "image=@/dev/null" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  --max-time 10 2>/dev/null)
check_code "Image edits → LiteLLM (expect 400 validation, HTTP $EDIT_CODE)" "$EDIT_CODE" "400" "422" "500"

# 17. Retired Nova Canvas sidecar paths are no longer routed (WAF blocks /v1/images/* except generations/edits)
echo "17. Retired sidecar image paths"
for retired in variations background-removal outpaint; do
  RETIRED_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/$retired" \
    -H "Authorization: Bearer $VALID_KEY" \
    -H "Content-Type: application/json" \
    "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
    -d '{"image":"invalid"}' \
    --max-time 10 2>/dev/null)
  check_code "/v1/images/$retired blocked (HTTP $RETIRED_CODE)" "$RETIRED_CODE" "403" "404" "405"
done

# --- Stability AI via LiteLLM /v1/images/edits ---

# 18. Stability AI inpaint via LiteLLM (free — bad input triggers validation error)
echo "18. Stability AI inpaint via LiteLLM"
INPAINT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -F "model=stability-inpaint" \
  -F "image=@/dev/null" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  --max-time 10 2>/dev/null)
check_code "Inpaint via LiteLLM (expect 400/422/500, HTTP $INPAINT_CODE)" "$INPAINT_CODE" "400" "422" "500"

# 19. Removed sidecar path returns 404
echo "19. Removed sidecar path returns 404"
REMOVED_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/structure" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid","prompt":"test"}' \
  --max-time 10 2>/dev/null)
check_code "Removed sidecar path → 403/404/405 (HTTP $REMOVED_CODE)" "$REMOVED_CODE" "403" "404" "405"

# --- Palette & style control (free — validation errors only, nothing reaches Bedrock) ---

# 20. Palette endpoint: bad hex rejected by sidecar (proves tunnel route + validation)
echo "20. Palette endpoint validation"
PAL_BAD_BODY=$(curl -s -X POST "$BASE_URL/v1/images/palette" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"prompt":"a lighthouse","colors":["not-hex"]}' \
  --max-time 10 2>/dev/null)
check "Palette rejects invalid hex (sidecar validation_error)" jq -e '.detail.error.type == "validation_error"' <<< "$PAL_BAD_BODY"

# 21. Palette endpoint: unauthenticated → 401 before anything is rendered
echo "21. Palette endpoint auth"
PAL_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/palette" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"prompt":"a lighthouse","colors":["#1e3a5f"]}' \
  --max-time 10 2>/dev/null)
check_code "Palette without key rejected (HTTP $PAL_AUTH_CODE)" "$PAL_AUTH_CODE" "401" "403"

# 22. Style-guide passthrough: fidelity/seed/negative_prompt reach LiteLLM (bad image → 400/422/500, not a routing 404)
echo "22. Style-guide param passthrough"
SG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -F "model=stability-style-guide" \
  -F "image=@/dev/null" \
  -F "prompt=a lighthouse" \
  -F "fidelity=0.8" \
  -F "seed=7" \
  -F "negative_prompt=neon" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  --max-time 10 2>/dev/null)
check_code "Style-guide with fidelity/seed/negative_prompt reaches LiteLLM (HTTP $SG_CODE)" "$SG_CODE" "400" "422" "500"

# 23. Model list contains LiteLLM image models
echo "23. LiteLLM image models"
check "Model list contains stable-image-ultra" grep -q "stable-image-ultra" <<< "$MODELS"
check "Model list contains stable-image-core" grep -q "stable-image-core" <<< "$MODELS"
check "Model list contains stability-inpaint" grep -q "stability-inpaint" <<< "$MODELS"
check "Model list contains stability-upscale" grep -q "stability-upscale" <<< "$MODELS"
check "Model list contains stability-structure" grep -q "stability-structure" <<< "$MODELS"

# Summary
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
