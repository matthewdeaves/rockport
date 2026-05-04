# shellcheck shell=bash
# scripts/lib/api.sh — Cloudflare tunnel URL, CF-Access header caching, and
# the api_call() helper used by every HTTP-touching subcommand. Sourced by
# rockport.sh. Relies on die().

CACHED_TUNNEL_URL=""
# shellcheck disable=SC2034 # consumed by api_call() in this file + sourced libs (diag, keys, spend, ssm)
CACHED_CF_CLIENT_ID=""
# shellcheck disable=SC2034 # consumed by api_call() in this file + sourced libs (diag, keys, spend, ssm)
CACHED_CF_CLIENT_SECRET=""

get_tunnel_url() {
  if [[ -n "$CACHED_TUNNEL_URL" ]]; then
    echo "$CACHED_TUNNEL_URL"
    return
  fi
  CACHED_TUNNEL_URL=$(cd "$TERRAFORM_DIR" && terraform output -raw tunnel_url 2>&1) || {
    echo "ERROR: Failed to get tunnel_url from terraform. Run './scripts/rockport.sh deploy' first." >&2
    return 1
  }
  echo "$CACHED_TUNNEL_URL"
}

ensure_cf_access_cached() {
  # Populate CACHED_CF_* from env vars or terraform output (once)
  if [[ -n "$CACHED_CF_CLIENT_ID" ]]; then
    return
  fi
  if [[ -n "${CF_ACCESS_CLIENT_ID:-}" && -n "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
    CACHED_CF_CLIENT_ID="$CF_ACCESS_CLIENT_ID"
    CACHED_CF_CLIENT_SECRET="$CF_ACCESS_CLIENT_SECRET"
    return
  fi
  CACHED_CF_CLIENT_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw cf_access_client_id 2>/dev/null) || CACHED_CF_CLIENT_ID=""
  CACHED_CF_CLIENT_SECRET=$(cd "$TERRAFORM_DIR" && terraform output -raw cf_access_client_secret 2>/dev/null) || CACHED_CF_CLIENT_SECRET=""
}

api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url
  url="$(get_tunnel_url)${path}"
  local key
  key="$(get_master_key)"

  # Build CF Access header args from cached values
  local cf_args=()
  if [[ -n "$CACHED_CF_CLIENT_ID" && -n "$CACHED_CF_CLIENT_SECRET" ]]; then
    cf_args=(-H "CF-Access-Client-Id: $CACHED_CF_CLIENT_ID" -H "CF-Access-Client-Secret: $CACHED_CF_CLIENT_SECRET")
  fi

  local http_code tmpfile
  tmpfile=$(mktemp) || die "Failed to create temp file"
  trap 'rm -f "$tmpfile"' RETURN

  if [[ -n "$data" ]]; then
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      "${cf_args[@]+"${cf_args[@]}"}" \
      -d "$data" \
      --max-time 30)
  else
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      "${cf_args[@]+"${cf_args[@]}"}" \
      --max-time 30)
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: API call $method $path failed with HTTP $http_code" >&2
    cat "$tmpfile" >&2
    return 1
  fi

  cat "$tmpfile"
}
