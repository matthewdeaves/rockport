# shellcheck shell=bash
# scripts/lib/diag.sh — health probes for `status` (HTTP + EC2 + service
# states) and `models` (LiteLLM model list). Sourced by rockport.sh.
# Relies on die(), api_call(), get_region().

cmd_status() {
  # 017: --instance flag asks for the in-VM resource block (free/uptime/nproc),
  # which requires ssm:SendCommand. The dispatcher has already escalated us to
  # runtime-ops if the flag is present; without it we run under readonly and
  # the SSM probe is skipped (FR-008 graceful degradation).
  local include_instance=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --instance) include_instance=true; shift ;;
      *) echo "Unknown status option: $1"; exit 1 ;;
    esac
  done

  local url key
  url="$(get_tunnel_url)"
  key="$(get_master_key)"
  echo "Checking health at $url..."
  local response
  response=$(api_call GET "/health") || { echo "Could not reach health endpoint."; return 1; }

  # Image model names that fail LiteLLM's built-in health probe (it sends max_tokens which they reject)
  local image_model_pattern="nova-canvas|sd3-5-large|titan-image|stable-image-ultra|stable-image-core"
  # image_edit models have no health check handler in LiteLLM (PR #21524 pending)
  # These use us.stability.* cross-region inference profile IDs
  local image_edit_pattern="us\.stability\.stable-image-control|us\.stability\.stable-style-transfer|us\.stability\.stable-image-remove|us\.stability\.stable-image-search|us\.stability\.stable-conservative|us\.stability\.stable-image-style|us\.stability\.stable-image-inpaint|us\.stability\.stable-image-erase|us\.stability\.stable-creative|us\.stability\.stable-fast|us\.stability\.stable-outpaint"

  # Build CF Access headers for direct curl calls
  local cf_status_args=()
  if [[ -n "$CACHED_CF_CLIENT_ID" && -n "$CACHED_CF_CLIENT_SECRET" ]]; then
    cf_status_args=(-H "CF-Access-Client-Id: $CACHED_CF_CLIENT_ID" -H "CF-Access-Client-Secret: $CACHED_CF_CLIENT_SECRET")
  fi

  # Check video sidecar health
  local video_health
  video_health=$(curl -s "$url/v1/videos/health" -H "Authorization: Bearer $key" "${cf_status_args[@]+"${cf_status_args[@]}"}" --max-time 5 2>/dev/null) || video_health=""
  if [[ -n "$video_health" ]]; then
    local video_status
    video_status=$(echo "$video_health" | jq -r '.status // "unknown"' 2>/dev/null)
    if [[ "$video_status" == "healthy" ]]; then
      echo "Video sidecar: healthy"
    else
      echo "Video sidecar: unhealthy"
    fi
    # Show per-model video status
    echo "$video_health" | jq -r '
      .models // {} | to_entries[] |
      "  video/\(.key): \(.value.status) (\(.value.region))"' 2>/dev/null
  else
    echo "Video sidecar: not reachable"
  fi

  local healthy unhealthy
  healthy=$(echo "$response" | jq -r '.healthy_endpoints[]?.model // empty')
  unhealthy=$(echo "$response" | jq -r '[.unhealthy_endpoints[]? | select(.model != null)] | map(.model) | .[]')

  # Split unhealthy into real failures vs image models needing manual probe vs image_edit (no probe possible)
  local real_unhealthy image_unhealthy image_edit_unhealthy
  image_edit_unhealthy=$(echo "$unhealthy" | grep -E "$image_edit_pattern" 2>/dev/null || true)
  local non_edit_unhealthy
  non_edit_unhealthy=$(echo "$unhealthy" | grep -vE "$image_edit_pattern" 2>/dev/null || true)
  real_unhealthy=$(echo "$non_edit_unhealthy" | grep -vE "$image_model_pattern" 2>/dev/null || true)
  image_unhealthy=$(echo "$non_edit_unhealthy" | grep -E "$image_model_pattern" 2>/dev/null || true)

  # Manually probe image models with a real generation request
  local image_healthy=""
  local image_failed=""
  if [[ -n "$image_unhealthy" ]]; then
    # Map Bedrock model IDs back to LiteLLM model names for the probe
    while IFS= read -r bedrock_model; do
      [[ -z "$bedrock_model" ]] && continue
      local litellm_name=""
      case "$bedrock_model" in
        *nova-canvas*)       litellm_name="nova-canvas" ;;
        *titan-image*)       litellm_name="titan-image-v2" ;;
        *sd3-5-large*)       litellm_name="sd3.5-large" ;;
        *stable-image-ultra*)  litellm_name="stable-image-ultra" ;;
        *stable-image-core*)   litellm_name="stable-image-core" ;;
        *)                   litellm_name="" ;;
      esac
      if [[ -n "$litellm_name" ]]; then
        # Use smallest valid size per model to minimize cost
        local probe_size="512x512"
        [[ "$litellm_name" == "nova-canvas" ]] && probe_size="320x320"
        local probe_code
        probe_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url/v1/images/generations" \
          -H "Authorization: Bearer $key" \
          -H "Content-Type: application/json" \
          "${cf_status_args[@]+"${cf_status_args[@]}"}" \
          -d "{\"model\":\"$litellm_name\",\"prompt\":\"test\",\"n\":1,\"size\":\"$probe_size\"}" \
          --max-time 30 2>/dev/null) || probe_code="000"
        if [[ "$probe_code" == "200" ]]; then
          image_healthy="${image_healthy}${bedrock_model}\n"
        else
          image_failed="${image_failed}${bedrock_model}\n"
        fi
      fi
    done <<< "$image_unhealthy"
  fi

  # Display results
  # Combine healthy lists
  local all_healthy
  all_healthy=$(printf "%s\n%b%s" "$healthy" "$image_healthy" "$image_edit_unhealthy" | sed '/^$/d' | grep -c . 2>/dev/null || true)
  echo "Healthy ($all_healthy):"
  echo "$healthy" | while IFS= read -r m; do
    [[ -n "$m" ]] && echo "  ✓ $m"
  done
  if [[ -n "$image_healthy" ]]; then
    printf "%b" "$image_healthy" | while IFS= read -r m; do
      [[ -n "$m" ]] && echo "  ✓ $m"
    done
  fi
  if [[ -n "$image_edit_unhealthy" ]]; then
    echo "$image_edit_unhealthy" | while IFS= read -r m; do
      [[ -n "$m" ]] && echo "  ✓ $m (image_edit — no health probe)"
    done
  fi

  # Show real failures
  local all_unhealthy
  all_unhealthy=$(printf "%s\n%b" "$real_unhealthy" "$image_failed" | sed '/^$/d')
  if [[ -n "$all_unhealthy" ]]; then
    local u_count
    u_count=$(echo "$all_unhealthy" | grep -c . 2>/dev/null || true)
    echo "Unhealthy ($u_count):"
    echo "$all_unhealthy" | while IFS= read -r m; do
      [[ -n "$m" ]] && echo "  ✗ $m"
    done
  fi

  # Instance resource usage via SSM (017: only with --instance; otherwise
  # we are running under readonly which has no ssm:SendCommand).
  if [[ "$include_instance" == "true" ]]; then
    echo ""
    echo "Instance:"
    local stats
    stats=$(ssm_run "free -m && echo === && uptime && echo === && nproc" 30 2>/dev/null) || stats=""
    if [[ -n "$stats" ]]; then
      local mem_used mem_total mem_pct swap_used swap_total load cpus upstr
      mem_total=$(echo "$stats" | awk '/^Mem:/{print $2}')
      mem_used=$(echo "$stats" | awk '/^Mem:/{print $3}')
      swap_total=$(echo "$stats" | awk '/^Swap:/{print $2}')
      swap_used=$(echo "$stats" | awk '/^Swap:/{print $3}')
      mem_pct=$((mem_used * 100 / mem_total))
      load=$(echo "$stats" | grep "load average" | sed 's/.*load average: //')
      cpus=$(echo "$stats" | tail -1)
      upstr=$(echo "$stats" | grep "load average" | sed 's/.*up //;s/,.*load.*//')
      echo "  Memory:   ${mem_used}/${mem_total}MB (${mem_pct}%)  Swap: ${swap_used}/${swap_total}MB"
      echo "  CPU:      load ${load} (${cpus} vCPU)"
      echo "  Uptime:   ${upstr}"
    else
      echo "  (could not retrieve instance stats)"
    fi
  else
    echo ""
    echo "Instance:"
    echo "  (instance stats require runtime-ops role; rerun with: rockport.sh status --instance)"
  fi
}

cmd_models() {
  echo "Listing models..."
  local response
  response=$(api_call GET "/v1/models")

  echo "$response" | jq -r '.data | sort_by(.id)[] | "  \(.id)"'
  echo
  echo "$response" | jq -r '"\(.data | length) models available"'
}
