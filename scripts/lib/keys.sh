# shellcheck shell=bash
# scripts/lib/keys.sh — virtual API key CRUD (LiteLLM /key/* endpoints) and
# the Claude-only allowlist derivation. Sourced by rockport.sh. Relies on
# die(), api_call().

claude_models() {
  local config_file="$CONFIG_DIR/litellm-config.yaml"
  [ -r "$config_file" ] || die "Cannot read $config_file — config/litellm-config.yaml is required to derive the Claude-only allowlist"

  # Grep for `- model_name: claude-...` lines (quoted or unquoted), strip the
  # prefix, trim whitespace, strip any surrounding quotes. Preserves literal
  # characters such as the square brackets in `claude-opus-4-7[1m]`.
  local raw
  raw=$(grep -E '^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*"?claude-' "$config_file" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')

  [ -n "$raw" ] || die "No 'model_name: claude-*' entries found in $config_file"

  # Emit compact JSON array, preserving literal characters.
  printf '%s\n' "$raw" | jq -R . | jq -s -c .
}

cmd_key_create() {
  local name="${1:?Usage: rockport key create <name> [--budget <amount>] [--claude-only]}"
  shift
  local budget=""
  local claude_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --budget) budget="${2:?--budget requires a dollar amount}"; shift 2 ;;
      --claude-only) claude_only=true; shift ;;
      *) echo "Unknown option: $1"; echo "Usage: rockport key create <name> [--budget <amount>] [--claude-only]"; exit 1 ;;
    esac
  done

  # Check for duplicate key name
  local existing
  existing=$(api_call GET "/key/list?return_full_object=true" 2>/dev/null || true)
  if [[ -n "$existing" ]] && echo "$existing" | jq -e --arg n "$name" '.keys[]? | select(.key_alias == $n)' > /dev/null 2>&1; then
    echo "ERROR: A key with name '$name' already exists. Choose a different name." >&2
    return 1
  fi

  local payload
  payload=$(jq -n --arg alias "$name" '{key_alias: $alias}') || die "Failed to build key payload"

  if [[ -n "$budget" ]]; then
    payload=$(echo "$payload" | jq --argjson budget "$budget" '. + {max_budget: $budget, budget_duration: "1d"}') \
      || die "Failed to add budget to payload"
  fi

  if [[ "$claude_only" == "true" ]]; then
    local claude_models_json
    claude_models_json=$(claude_models) || die "Failed to derive Claude-only model allowlist"
    payload=$(echo "$payload" | jq --argjson models "$claude_models_json" '. + {models: $models}') \
      || die "Failed to add model restriction to payload"
    echo "Restricting key to Anthropic models only."
  fi

  echo "Creating key '$name'..."
  local response
  response=$(api_call POST "/key/generate" "$payload") || die "Failed to create API key"

  local key
  key=$(echo "$response" | jq -r '.key // empty')

  echo "$response" | jq -r '
    "Key:    \(.key // "?")",
    "Name:   \(.key_alias // "?")",
    "ID:     \(.token // "?")"
    + (if .max_budget then "\nBudget: $\(.max_budget)/day" else "" end)
    + (if .models and (.models | length) > 0 then "\nModels: \(.models | join(", "))" else "\nModels: all" end)'

  # Generate settings file for this key
  if [[ -n "$key" ]]; then
    local url
    url="$(get_tunnel_url)"

    # Include CF Access headers if configured
    local cf_id_k="$CACHED_CF_CLIENT_ID"
    local cf_secret_k="$CACHED_CF_CLIENT_SECRET"

    local settings_file="$CONFIG_DIR/claude-code-settings-${name}.json"
    if [[ -n "$cf_id_k" && -n "$cf_secret_k" ]]; then
      cat > "$settings_file" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$url",
    "ANTHROPIC_AUTH_TOKEN": "$key"
  },
  "apiKeyHelper": "echo $key",
  "defaultHeaders": {
    "CF-Access-Client-Id": "$cf_id_k",
    "CF-Access-Client-Secret": "$cf_secret_k"
  }
}
EOF
    else
      cat > "$settings_file" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$url",
    "ANTHROPIC_AUTH_TOKEN": "$key"
  }
}
EOF
    fi
    echo
    echo "Settings file: $settings_file"
    echo "Copy to ~/.claude/settings.json to use with Claude Code"
  fi
}

cmd_key_list() {
  echo "Listing keys..."
  local response
  response=$(api_call GET "/key/list?return_full_object=true")

  echo "$response" | jq -r '
    (.keys // .) | map(select(type == "object")) |
    if length == 0 then "  No keys found."
    else .[] |
      (.key_alias // .key_name // "unnamed") as $name |
      ($name | if length > 24 then .[0:24] else . + (" " * (24 - length)) end) as $padded |
      "  \($padded)  \(.token[:8])...  $\(.spend // 0 | . * 100 | round / 100)" +
      (if .max_budget then "  (limit: $\(.max_budget)/day)" else "" end) +
      (if .models and (.models | length) > 0 then "  [restricted]" else "" end)
    end'
}

cmd_key_info() {
  local key="${1:?Usage: rockport key info <key>}"
  local encoded_key
  encoded_key=$(printf '%s' "$key" | jq -sRr @uri)
  local response
  response=$(api_call GET "/key/info?key=$encoded_key")

  echo "$response" | jq -r '
    (.info // .) as $i |
    "Name:      \($i.key_alias // $i.key_name // "?")",
    "Spend:     $\($i.spend // 0 | . * 100 | round / 100)",
    "Max Budget:\(if $i.max_budget then " $\($i.max_budget)/day" else " unlimited" end)",
    "RPM Limit: \($i.rpm_limit // "default")",
    "TPM Limit: \($i.tpm_limit // "default")",
    "Models:    \(if $i.models and ($i.models | length) > 0 then ($i.models | join(", ")) else "all" end)",
    "Created:   \($i.created_at // "?")",
    "Expires:   \($i.expires // "never")"'
}

cmd_key_revoke() {
  local key="${1:?Usage: rockport key revoke <key>}"
  echo "Revoking key..."
  local payload
  payload=$(jq -n --arg k "$key" '{keys: [$k]}') || die "Failed to build revoke payload"
  local response
  response=$(api_call POST "/key/delete" "$payload") || die "Failed to revoke key"
  echo "$response" | jq -r '
    if .deleted_keys and (.deleted_keys | length) > 0 then
      "Revoked: \(.deleted_keys | join(", "))"
    else
      "No keys were revoked."
    end'
}

cmd_setup_claude() {
  local key_name
  read -rp "Key name [claude-code]: " key_name
  key_name="${key_name:-claude-code}"

  cmd_key_create "$key_name" --claude-only

  local settings_file="$CONFIG_DIR/claude-code-settings-${key_name}.json"
  if [[ -f "$settings_file" ]]; then
    echo
    echo "To configure Claude Code, copy the settings file:"
    echo "  cp $settings_file ~/.claude/settings.json"
  fi
}

# --- Main ---
