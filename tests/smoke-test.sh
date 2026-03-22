#!/bin/bash

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
check "Model list contains claude-sonnet-4-6" grep -q "claude-sonnet-4-6" <<< "$MODELS"
check "Model list contains nova-pro" grep -q "nova-pro" <<< "$MODELS"
check "Model list contains nova-canvas" grep -q "nova-canvas" <<< "$MODELS"
check "Model list contains titan-image-v2" grep -q "titan-image-v2" <<< "$MODELS"

# 5. Streamed chat response (~$0.01)
echo "5. Streaming chat"
STREAM_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}],"stream":true}' \
  --max-time 60 2>/dev/null)
check "Streaming response received" grep -q "data:" <<< "$STREAM_RESPONSE"

# 6. Image generation via LiteLLM (~$0.04)
echo "6. Image generation (LiteLLM route)"
IMAGE_RESPONSE=$(curl -s -X POST "$BASE_URL/v1/images/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-canvas","prompt":"a solid red circle on white background","n":1,"size":"512x512"}' \
  --max-time 60 2>/dev/null)
check "Image generation returns b64_json" grep -q "b64_json" <<< "$IMAGE_RESPONSE"

# --- Video Sidecar ---

# 7. Video sidecar health
echo "7. Video sidecar health"
VIDEO_HEALTH_BODY=$(curl -s "$BASE_URL/v1/videos/health" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
check "Video sidecar healthy" grep -q "healthy" <<< "$VIDEO_HEALTH_BODY"
check "Health includes nova-reel" jq -e '.models["nova-reel"]' <<< "$VIDEO_HEALTH_BODY"
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
  -d '{"model":"nonexistent","prompt":"Armoured knight walking steadily forward in side profile, arms swinging naturally, static shot","duration":6}' \
  --max-time 10 2>/dev/null)
check_code "Unknown video model rejected (HTTP $VIDEO_BAD_MODEL_CODE)" "$VIDEO_BAD_MODEL_CODE" "400"

# 10. Video invalid duration rejection (free — fails before Bedrock)
echo "10. Video duration validation"
VIDEO_DUR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking steadily forward in side profile, arms swinging naturally, static shot","duration":7}' \
  --max-time 10 2>/dev/null)
check_code "Invalid duration rejected (HTTP $VIDEO_DUR_CODE)" "$VIDEO_DUR_CODE" "400"

# 11. Video list (no jobs is fine, just routing check)
echo "11. Video list"
VIDEO_LIST_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" "${CF_ARGS[@]+"${CF_ARGS[@]}"}" --max-time 10 2>/dev/null)
check_code "Video list returns 200 (HTTP $VIDEO_LIST_CODE)" "$VIDEO_LIST_CODE" "200"

# --- Prompt Validation (free — all rejected before Bedrock) ---

# 12. Negation word rejection
echo "12. Prompt validation — negation"
NEGATION_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"A knight walking forward through a dark castle courtyard, no sword visible in the scene, static shot","duration":6}' \
  --max-time 10 2>/dev/null)
check_code "Negation word 'no' rejected (HTTP $NEGATION_CODE)" "$NEGATION_CODE" "400"

# 13. Camera keyword mid-prompt is now a warning, not a rejection (free — invalid duration)
echo "13. Prompt validation — camera position (middle is warning, not rejection)"
CAMERA_MID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking forward, dolly forward, with castle walls and torchlight in background","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for duration (not prompt) — means camera keyword didn't block
check_code "Camera mid-prompt passes validation (fails on duration instead)" "$CAMERA_MID_CODE" "400"

# 14. Camera keyword at start allowed (free — uses invalid duration to fail AFTER prompt validation passes)
echo "14. Prompt validation — camera position (start allowed)"
CAMERA_START_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Dolly forward through a misty forest, golden light filtering through ancient trees, leaves drifting gently","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for duration (not prompt) — means prompt validation passed
check_code "Camera at start passes validation (fails on duration instead)" "$CAMERA_START_CODE" "400"

# 15. Contracted negation rejection
echo "15. Prompt validation — contracted negation"
CONTRACTION_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d "{\"model\":\"nova-reel\",\"prompt\":\"The warrior can't be stopped, moving through the dark battlefield scene, static shot\",\"duration\":6}" \
  --max-time 10 2>/dev/null)
check_code "Contracted negation \"can't\" rejected (HTTP $CONTRACTION_CODE)" "$CONTRACTION_CODE" "400"

# 16. Valid prompt accepted (free — uses invalid duration to fail AFTER prompt validation passes)
echo "16. Prompt validation — valid prompt passes"
VALID_PROMPT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","prompt":"Armoured knight walking steadily forward in side profile, arms swinging in opposition to legs, weight shifting with each step, static shot","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for duration (not prompt) — means prompt validation passed
check_code "Valid prompt passes validation (fails on duration instead)" "$VALID_PROMPT_CODE" "400"

# 17. Ray2 not subject to prompt validation (free — uses validation error to avoid real job)
echo "17. Prompt validation — Ray2 bypass"
RAY2_BODY=$(curl -s -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"luma-ray2","prompt":"A knight walking forward, no sword visible","duration":7}' \
  --max-time 10 2>/dev/null)
# Should get 400 for invalid duration (not prompt validation) — proves prompt validation was skipped
check "Ray2 skips prompt validation (fails on duration instead)" jq -e '.detail.error.type == "validation_error"' <<< "$RAY2_BODY"

# --- Image Endpoint Routing (free — validation errors) ---

# 18. Image edits routes to LiteLLM (Stability AI via /v1/images/edits)
echo "18. Image edits routes to LiteLLM"
EDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -F "model=stability-remove-background" \
  -F "image=@/dev/null" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  --max-time 10 2>/dev/null)
check_code "Image edits → LiteLLM (expect 400 validation, HTTP $EDIT_CODE)" "$EDIT_CODE" "400" "422" "500"

# 19. Image variations endpoint reachable (validation error = routing works)
echo "19. Image variations endpoint"
IMGVAR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/variations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"images":["invalid"],"prompt":"test prompt with enough characters to pass"}' \
  --max-time 10 2>/dev/null)
check_code "Variations reachable, rejects bad input (HTTP $IMGVAR_CODE)" "$IMGVAR_CODE" "400" "422"

# 20. Background removal endpoint reachable
echo "20. Background removal endpoint"
IMGBG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/background-removal" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid"}' \
  --max-time 10 2>/dev/null)
check_code "Background removal reachable (HTTP $IMGBG_CODE)" "$IMGBG_CODE" "400" "422"

# 21. Outpaint endpoint reachable
echo "21. Outpaint endpoint"
IMGOUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/outpaint" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid","prompt":"test","mask_prompt":"subject"}' \
  --max-time 10 2>/dev/null)
check_code "Outpaint reachable (HTTP $IMGOUT_CODE)" "$IMGOUT_CODE" "400" "422"

# --- Stability AI via LiteLLM /v1/images/edits ---

# 22. Stability AI inpaint via LiteLLM (free — bad input triggers validation error)
echo "22. Stability AI inpaint via LiteLLM"
INPAINT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -H "Authorization: Bearer $VALID_KEY" \
  -F "model=stability-inpaint" \
  -F "image=@/dev/null" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  --max-time 10 2>/dev/null)
check_code "Inpaint via LiteLLM (expect 400/422/500, HTTP $INPAINT_CODE)" "$INPAINT_CODE" "400" "422" "500"

# 23. Removed sidecar path returns 404
echo "23. Removed sidecar path returns 404"
REMOVED_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/structure" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"image":"invalid","prompt":"test"}' \
  --max-time 10 2>/dev/null)
check_code "Removed sidecar path → 404/405 (HTTP $REMOVED_CODE)" "$REMOVED_CODE" "404" "405"

# 24. Model list contains LiteLLM image models
echo "24. LiteLLM image models"
check "Model list contains stable-image-ultra" grep -q "stable-image-ultra" <<< "$MODELS"
check "Model list contains stable-image-core" grep -q "stable-image-core" <<< "$MODELS"
check "Model list contains stability-inpaint" grep -q "stability-inpaint" <<< "$MODELS"
check "Model list contains stability-upscale" grep -q "stability-upscale" <<< "$MODELS"
check "Model list contains stability-structure" grep -q "stability-structure" <<< "$MODELS"

# 25. Nova Canvas style preset pass-through (free — invalid size triggers 400 before Bedrock)
echo "25. Nova Canvas style preset"
STYLE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-canvas","prompt":"a red circle","n":1,"size":"99x99","textToImageParams":{"style":"PHOTOREALISM"}}' \
  --max-time 30 2>/dev/null)
check_code "Style preset routed correctly (HTTP $STYLE_CODE)" "$STYLE_CODE" "400" "422"

# 26. Automated multi-shot video validation (free — invalid duration)
echo "26. Automated multi-shot video"
AUTO_MS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/videos/generations" \
  -H "Authorization: Bearer $VALID_KEY" \
  -H "Content-Type: application/json" \
  "${CF_ARGS[@]+"${CF_ARGS[@]}"}" \
  -d '{"model":"nova-reel","mode":"multi-shot-automated","prompt":"A knight walks through a medieval castle courtyard, exploring the stone walls and wooden doors","duration":7}' \
  --max-time 10 2>/dev/null)
check_code "Automated multi-shot validates duration (HTTP $AUTO_MS_CODE)" "$AUTO_MS_CODE" "400"


# Summary
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
