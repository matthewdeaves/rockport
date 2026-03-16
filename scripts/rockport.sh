#!/bin/bash
set -euo pipefail

MASTER_KEY_SSM_PATH="/rockport/master-key"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)" || { echo "ERROR: terraform/ directory not found" >&2; exit 1; }
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "ERROR: config/ directory not found" >&2; exit 1; }
ENV_FILE="$TERRAFORM_DIR/.env"
CACHED_MASTER_KEY=""
CACHED_REGION=""
CACHED_INSTANCE_ID=""
CACHED_TUNNEL_URL=""

# Anthropic model names for Claude Code key restrictions
CLAUDE_MODELS='["claude-opus-4-6","claude-sonnet-4-6","claude-haiku-4-5-20251001","claude-sonnet-4-5-20250929","claude-opus-4-5-20251101"]'

# Use the rockport AWS profile if it exists and no profile is already set
if [[ -z "${AWS_PROFILE:-}" ]] && aws configure list-profiles 2>/dev/null | grep -q '^rockport$'; then
  export AWS_PROFILE=rockport
fi

# --- Helper functions ---

check_dependencies() {
  for cmd in aws terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found. Run ./scripts/setup.sh first." >&2
      exit 1
    fi
  done
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

get_region() {
  if [[ -n "$CACHED_REGION" ]]; then
    echo "$CACHED_REGION"
    return
  fi
  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    local r
    r=$(sed -n 's/^region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) && [[ -n "$r" ]] && {
      CACHED_REGION="$r"
      echo "$r"
      return
    }
  fi
  local r
  r=$(cd "$TERRAFORM_DIR" && terraform output -raw region 2>/dev/null) && {
    CACHED_REGION="$r"
    echo "$r"
    return
  }
  echo "WARNING: Could not determine region. Using default: eu-west-2" >&2
  CACHED_REGION="eu-west-2"
  echo "$CACHED_REGION"
}

get_master_key() {
  if [[ -n "$CACHED_MASTER_KEY" ]]; then
    echo "$CACHED_MASTER_KEY"
    return
  fi
  CACHED_MASTER_KEY=$(aws ssm get-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$(get_region)") || {
    echo "ERROR: Failed to fetch master key from SSM. Is the infrastructure deployed?" >&2
    return 1
  }
  echo "$CACHED_MASTER_KEY"
}

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

get_instance_id() {
  if [[ -n "$CACHED_INSTANCE_ID" ]]; then
    echo "$CACHED_INSTANCE_ID"
    return
  fi
  CACHED_INSTANCE_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw instance_id 2>&1) || {
    echo "ERROR: Failed to get instance_id from terraform. Run './scripts/rockport.sh deploy' first." >&2
    return 1
  }
  echo "$CACHED_INSTANCE_ID"
}

# Run a command on the instance via SSM and return stdout.
# Usage: ssm_run <command_string> [timeout_seconds]
ssm_run() {
  local cmd_string="$1"
  local timeout="${2:-30}"
  local instance_id region cmd_id
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$cmd_string\"]}" \
    --timeout-seconds "$timeout" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  # Poll for completion
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$region" \
      --query 'Status' \
      --output text 2>/dev/null) || true
    case "$status" in
      Success)
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardOutputContent' \
          --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo "ERROR: Command $status" >&2
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardErrorContent' \
          --output text >&2
        return 1
        ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "ERROR: Timed out waiting for command result" >&2
  return 1
}

# Ensure the master key exists in SSM. Creates one if missing.
ensure_master_key() {
  local region="$1"
  if aws ssm get-parameter --name "$MASTER_KEY_SSM_PATH" --region "$region" &>/dev/null 2>&1; then
    echo "  Master key ........... ok (exists in SSM)"
  else
    local master_key
    master_key="sk-$(openssl rand -hex 24)"
    aws ssm put-parameter \
      --name "$MASTER_KEY_SSM_PATH" \
      --value "$master_key" \
      --type SecureString \
      --region "$region" >/dev/null
    echo "  Master key ........... created in SSM"
  fi
}

api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url
  url="$(get_tunnel_url)${path}"
  local key
  key="$(get_master_key)"

  local http_code tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' RETURN

  if [[ -n "$data" ]]; then
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -d "$data" \
      --max-time 30)
  else
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      --max-time 30)
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: API call $method $path failed with HTTP $http_code" >&2
    cat "$tmpfile" >&2
    return 1
  fi

  cat "$tmpfile"
}

get_state_bucket() {
  local region
  region="$(get_region)"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region")
  echo "rockport-tfstate-${account_id}-${region}"
}

# Delete all non-default versions of an IAM policy (required before policy deletion)
delete_all_policy_versions() {
  local arn="$1"
  local versions
  versions=$(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
  for v in $versions; do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" 2>/dev/null || true
  done
}

# Create or update an IAM managed policy. Returns 1 if creation fails (bootstrap).
upsert_iam_policy() {
  local name="$1" file="$2" account_id="$3"
  local arn="arn:aws:iam::${account_id}:policy/${name}"

  if aws iam get-policy --policy-arn "$arn" &>/dev/null; then
    delete_all_policy_versions "$arn"
    aws iam create-policy-version \
      --policy-arn "$arn" \
      --policy-document "file://$file" \
      --set-as-default >/dev/null
    echo "  IAM policy ........... updated ($name)"
  else
    if ! aws iam create-policy \
      --policy-name "$name" \
      --policy-document "file://$file" >/dev/null 2>&1; then
      return 1
    fi
    echo "  IAM policy ........... created ($name)"
  fi
}

# Attach an IAM policy to a user if not already attached
attach_iam_policy() {
  local user="$1" name="$2" account_id="$3"
  local arn="arn:aws:iam::${account_id}:policy/${name}"

  if aws iam list-attached-user-policies --user-name "$user" \
    --query "AttachedPolicies[?PolicyArn=='$arn']" --output text 2>/dev/null | grep -q "$name"; then
    echo "  Policy attachment .... ok ($name → $user)"
  else
    aws iam attach-user-policy --user-name "$user" --policy-arn "$arn"
    echo "  Policy attachment .... attached ($name → $user)"
  fi
}

ensure_deployer_access() {
  local deployer_user="rockport-deployer"
  local policy_dir="$TERRAFORM_DIR/deployer-policies"
  local account_id caller_user
  local caller_identity
  caller_identity=$(aws sts get-caller-identity --output json)
  account_id=$(echo "$caller_identity" | jq -r '.Account')
  caller_user=$(echo "$caller_identity" | jq -r '.Arn' | sed 's|.*/||')

  # --- Admin policy (self-bootstrapping) ---
  # The RockportAdmin policy grants the admin user permission to manage all
  # deployer policies. On first-ever run, this policy must be created manually
  # via the AWS console or an IAM admin (chicken-and-egg).
  if ! upsert_iam_policy "RockportAdmin" "$TERRAFORM_DIR/rockport-admin-policy.json" "$account_id"; then
    echo
    echo "ERROR: Cannot create the RockportAdmin policy."
    echo "First-time bootstrap requires an IAM admin to create and attach it:"
    echo
    echo "  1. IAM → Policies → Create policy → JSON tab"
    echo "     Paste contents of: terraform/rockport-admin-policy.json"
    echo "     Name: RockportAdmin"
    echo "  2. IAM → Users → $caller_user → Attach policies → RockportAdmin"
    echo
    echo "Then re-run: ./scripts/rockport.sh init"
    return 1
  fi
  attach_iam_policy "$caller_user" "RockportAdmin" "$account_id"

  # --- Deployer policies ---
  local policy_names=("RockportDeployerCompute" "RockportDeployerIamSsm" "RockportDeployerMonitoringStorage")
  local policy_files=("$policy_dir/compute.json" "$policy_dir/iam-ssm.json" "$policy_dir/monitoring-storage.json")

  for i in "${!policy_names[@]}"; do
    upsert_iam_policy "${policy_names[$i]}" "${policy_files[$i]}" "$account_id"
  done

  # --- Deployer user ---
  if aws iam get-user --user-name "$deployer_user" &>/dev/null; then
    echo "  IAM user ............. ok ($deployer_user)"
  else
    aws iam create-user --user-name "$deployer_user" >/dev/null
    echo "  IAM user ............. created ($deployer_user)"
  fi

  # Attach deployer policies to both the deployer user and the calling user
  # so deploy/destroy work regardless of which user runs them
  for user in "$deployer_user" "$caller_user"; do
    for i in "${!policy_names[@]}"; do
      attach_iam_policy "$user" "${policy_names[$i]}" "$account_id"
    done
  done

  local existing_keys
  existing_keys=$(aws iam list-access-keys --user-name "$deployer_user" --query 'length(AccessKeyMetadata)' --output text)

  if [[ "$existing_keys" -gt 0 ]]; then
    echo "  Access keys .......... ok (already configured)"
  else
    local key_output
    key_output=$(aws iam create-access-key --user-name "$deployer_user" --output json)
    local access_key secret_key
    access_key=$(echo "$key_output" | jq -r '.AccessKey.AccessKeyId')
    secret_key=$(echo "$key_output" | jq -r '.AccessKey.SecretAccessKey')

    local region
    region="$(get_region)"

    aws configure set aws_access_key_id "$access_key" --profile rockport
    aws configure set aws_secret_access_key "$secret_key" --profile rockport
    aws configure set region "$region" --profile rockport
    aws configure set output json --profile rockport
    export AWS_PROFILE=rockport

    echo "  Access keys .......... created (profile 'rockport' configured)"
  fi
}

ensure_state_backend() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  if aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    echo "  State bucket ......... ok ($bucket)"
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null || {
      echo "ERROR: Failed to create S3 state bucket '$bucket'" >&2
      return 1
    }

    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --region "$region" \
      --versioning-configuration Status=Enabled

    aws s3api put-bucket-encryption \
      --bucket "$bucket" \
      --region "$region" \
      --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}, "BucketKeyEnabled": true}]
      }'

    aws s3api put-public-access-block \
      --bucket "$bucket" \
      --region "$region" \
      --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    echo "  State bucket ......... created ($bucket)"
  fi
}

# Wait for the health endpoint to respond (200 or 401 means service is up).
wait_for_health() {
  local url="$1"
  local timeout="${2:-120}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url/health" --max-time 5 2>/dev/null) || true
    # 200 = healthy, 401 = auth required but service is up — both mean ready
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      echo "Services healthy. Rockport is ready."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "\r  Waiting for services... %ds" "$elapsed"
  done
  echo
  echo "WARNING: Health check did not respond within ${timeout}s."
  echo "Services may still be starting. Check with: rockport status"
  return 1
}

# --- Subcommands ---

cmd_init() {
  echo "Rockport Setup"
  echo "=============="
  echo

  for cmd in aws terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found. Run ./scripts/setup.sh first."
      exit 1
    fi
  done

  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    echo "Existing terraform.tfvars found."
    read -rp "Overwrite? [y/N]: " overwrite
    if [[ "$overwrite" != [yY] ]]; then
      load_env
      local region
      region="$(get_region)"

      echo
      echo "Checking prerequisites..."
      ensure_deployer_access
      ensure_master_key "$region"
      ensure_state_backend
      echo "  Config ............... ok (using existing terraform.tfvars)"

      echo
      echo "All prerequisites met. Run: ./scripts/rockport.sh deploy"
      return 0
    fi
  fi

  read -rp "AWS region [eu-west-2]: " region
  region="${region:-eu-west-2}"
  if [[ ! "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    echo "ERROR: Invalid AWS region format: $region"; exit 1
  fi

  read -rp "Domain (e.g. llm.example.com): " domain
  [[ -z "$domain" ]] && { echo "Domain is required."; exit 1; }
  if [[ ! "$domain" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]]; then
    echo "ERROR: Invalid domain format: $domain"; exit 1
  fi

  read -rp "Cloudflare Zone ID: " cf_zone_id
  [[ -z "$cf_zone_id" ]] && { echo "Zone ID is required."; exit 1; }
  if [[ ! "$cf_zone_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "ERROR: Zone ID must be a 32-character hex string"; exit 1
  fi

  read -rp "Cloudflare Account ID: " cf_account_id
  [[ -z "$cf_account_id" ]] && { echo "Account ID is required."; exit 1; }
  if [[ ! "$cf_account_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "ERROR: Account ID must be a 32-character hex string"; exit 1
  fi

  read -rp "Cloudflare API Token: " cf_api_token
  [[ -z "$cf_api_token" ]] && { echo "API Token is required."; exit 1; }

  read -rp "Budget alert email: " email
  [[ -z "$email" ]] && { echo "Email is required."; exit 1; }
  if [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo "ERROR: Invalid email format: $email"; exit 1
  fi

  local subdomain
  subdomain="${domain%%.*}"

  (
    umask 077
    cat > "$ENV_FILE" <<EOF
export CLOUDFLARE_API_TOKEN="$cf_api_token"
EOF
  )
  echo "Written to terraform/.env"

  cat > "$TERRAFORM_DIR/terraform.tfvars" <<EOF
region                = "$region"
domain                = "$domain"
tunnel_subdomain      = "$subdomain"
cloudflare_zone_id    = "$cf_zone_id"
cloudflare_account_id = "$cf_account_id"
budget_alert_email    = "$email"
EOF

  echo
  echo "Setting up prerequisites..."
  echo "  Config ............... written (terraform.tfvars + .env)"

  ensure_deployer_access
  ensure_master_key "$region"
  ensure_state_backend

  echo
  echo "Setup complete. Next steps:"
  echo "  1. Enable Bedrock model access in the AWS Console ($region)"
  echo "     For image generation, also enable models in us-west-2"
  if [[ "$region" != eu-* ]]; then
    echo "  2. Update model prefixes in config/litellm-config.yaml"
    echo "     (remove 'eu.' prefix for non-EU regions)"
    echo "  3. Run: ./scripts/rockport.sh deploy"
  else
    echo "  2. Run: ./scripts/rockport.sh deploy"
  fi
  echo
  echo "Tip: Add a quick-start alias to your shell profile:"
  echo "  echo 'alias rockport-start=\"$SCRIPT_DIR/rockport.sh start\"' >> ~/.bashrc"
}

cmd_status() {
  local url key
  url="$(get_tunnel_url)"
  key="$(get_master_key)"
  echo "Checking health at $url..."
  local response
  response=$(api_call GET "/health") || { echo "Could not reach health endpoint."; return 1; }

  # Image model names that fail LiteLLM's built-in health probe (it sends max_tokens which they reject)
  local image_model_pattern="nova-canvas|sd3-5-large|titan-image"

  # Check video sidecar health
  local video_health
  video_health=$(curl -s "$url/v1/videos/health" -H "Authorization: Bearer $key" --max-time 5 2>/dev/null) || video_health=""
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

  # Split unhealthy into real failures vs image models needing manual probe
  local real_unhealthy image_unhealthy
  real_unhealthy=$(echo "$unhealthy" | grep -vE "$image_model_pattern" 2>/dev/null || true)
  image_unhealthy=$(echo "$unhealthy" | grep -E "$image_model_pattern" 2>/dev/null || true)

  # Manually probe image models with a real generation request
  local image_healthy=""
  local image_failed=""
  if [[ -n "$image_unhealthy" ]]; then
    # Map Bedrock model IDs back to LiteLLM model names for the probe
    while IFS= read -r bedrock_model; do
      [[ -z "$bedrock_model" ]] && continue
      local litellm_name=""
      case "$bedrock_model" in
        *nova-canvas*)    litellm_name="nova-canvas" ;;
        *titan-image*)    litellm_name="titan-image-v2" ;;
        *sd3-5-large*)    litellm_name="sd3.5-large" ;;
        *)                litellm_name="" ;;
      esac
      if [[ -n "$litellm_name" ]]; then
        # Use smallest valid size per model to minimize cost
        local probe_size="512x512"
        [[ "$litellm_name" == "nova-canvas" ]] && probe_size="320x320"
        local probe_code
        probe_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url/v1/images/generations" \
          -H "Authorization: Bearer $key" \
          -H "Content-Type: application/json" \
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
  all_healthy=$(printf "%s\n%b" "$healthy" "$image_healthy" | grep -c . 2>/dev/null || true)
  echo "Healthy ($all_healthy):"
  echo "$healthy" | while IFS= read -r m; do
    [[ -n "$m" ]] && echo "  ✓ $m"
  done
  if [[ -n "$image_healthy" ]]; then
    printf "%b" "$image_healthy" | while IFS= read -r m; do
      [[ -n "$m" ]] && echo "  ✓ $m"
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
  payload=$(jq -n --arg alias "$name" '{key_alias: $alias}')

  if [[ -n "$budget" ]]; then
    payload=$(echo "$payload" | jq --argjson budget "$budget" '. + {max_budget: $budget, budget_duration: "1d"}')
  fi

  if [[ "$claude_only" == "true" ]]; then
    payload=$(echo "$payload" | jq --argjson models "$CLAUDE_MODELS" '. + {models: $models}')
    echo "Restricting key to Anthropic models only."
  fi

  echo "Creating key '$name'..."
  local response
  response=$(api_call POST "/key/generate" "$payload")

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
    local settings_file="$CONFIG_DIR/claude-code-settings-${name}.json"
    cat > "$settings_file" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$url",
    "ANTHROPIC_AUTH_TOKEN": "$key"
  }
}
EOF
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
  payload=$(jq -n --arg k "$key" '{keys: [$k]}')
  local response
  response=$(api_call POST "/key/delete" "$payload")
  echo "$response" | jq -r '
    if .deleted_keys and (.deleted_keys | length) > 0 then
      "Revoked: \(.deleted_keys | join(", "))"
    else
      "No keys were revoked."
    end'
}

cmd_models() {
  echo "Listing models..."
  local response
  response=$(api_call GET "/v1/models")

  echo "$response" | jq -r '.data | sort_by(.id)[] | "  \(.id)"'
  echo
  echo "$response" | jq -r '"\(.data | length) models available"'
}

cmd_spend() {
  local subcmd="${1:-}"

  case "$subcmd" in
    keys)
      local response
      response=$(api_call GET "/key/list?return_full_object=true")

      echo "$response" | jq -r '
        (.keys // .) | map(select(type == "object")) |
        if length == 0 then "  No keys found."
        else
          "Spend by Key (current budget period)",
          "─────────────────────────────────────────",
          (sort_by(.spend // 0) | reverse | . as $keys |
            ($keys[] |
              (.key_alias // .key_name // "unnamed") as $name |
              ($name | if length > 24 then .[0:24] else .[0:24] + (" " * ([24 - length, 0] | max)) end) as $padded |
              "  \($padded)  $\(.spend // 0 | . * 100 | round / 100)" +
              (if .max_budget then "  / $\(.max_budget)/day" else "" end)
            ),
            "",
            "  Total:                            $\($keys | map(.spend // 0) | add | . * 100 | round / 100)"
          )
        end'
      ;;
    *)
      # Default: combined summary
      echo "Rockport Spend Summary"
      echo "═══════════════════════════════════════════════"
      echo

      local global
      global=$(api_call GET "/global/spend") || { echo "Could not fetch spend data."; return 1; }
      local total_spend
      total_spend=$(echo "$global" | jq -r 'if type == "array" then (map(.spend // 0) | add) else (.spend // 0) end | . * 100 | round / 100')
      echo "All-time spend:  \$$total_spend"
      echo

      local keys
      keys=$(api_call GET "/key/list?return_full_object=true" 2>/dev/null) || true

      if [[ -n "$keys" ]]; then
        echo "$keys" | jq -r '
          (.keys // .) | map(select(type == "object")) |
          if length == 0 then empty
          else
            "By Key (current budget period):",
            "───────────────────────────────────────────────",
            (sort_by(.spend // 0) | reverse | .[] |
              (.key_alias // .key_name // "unnamed") as $name |
              ($name | if length > 24 then .[0:24] else .[0:24] + (" " * ([24 - length, 0] | max)) end) as $padded |
              "  \($padded)  $\(.spend // 0 | . * 100 | round / 100)" +
              (if .max_budget then "  / $\(.max_budget)/day" else "" end)
            ),
            ""
          end'
      fi

      echo "Run 'rockport spend keys' for key-only view."
      ;;
  esac
}

cmd_monitor() {
  local live=false
  local interval=2
  local log_count=15

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=true; shift ;;
      --interval) interval="${2:?--interval requires seconds}"; shift 2 ;;
      --count) log_count="${2:?--count requires a number}"; shift 2 ;;
      *) echo "Unknown option: $1"; echo "Usage: rockport monitor [--live] [--interval N] [--count N]"; return 1 ;;
    esac
  done

  local url key today
  url="$(get_tunnel_url)"
  key="$(get_master_key)"
  today=$(date -u +%Y-%m-%d)

  render_monitor() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    # Fetch key list and spend logs in parallel
    local keys_data logs_data
    keys_data=$(curl -s "$url/key/list?return_full_object=true" \
      -H "Authorization: Bearer $key" --max-time 10 2>/dev/null) || keys_data='{"keys":[]}'
    logs_data=$(curl -s "$url/spend/logs?start_date=$today" \
      -H "Authorization: Bearer $key" --max-time 10 2>/dev/null) || logs_data='[]'

    # Header
    echo "Rockport Monitor                                    $now"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo

    # Keys table
    echo "$keys_data" | jq -r --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (.keys // .) | map(select(type == "object")) |
      if length == 0 then
        "  No keys.\n"
      else
        "  Key                     Spend      Budget       Models     Last Active",
        "  ────────────────────────────────────────────────────────────────────────────",
        (sort_by(.last_active // "0") | reverse | .[] |
          (.key_alias // .key_name // "unnamed") as $name |
          ($name | if length > 22 then .[0:22] else . + (" " * ([22 - length, 0] | max)) end) as $pad_name |

          # Spend
          ("$\(.spend // 0 | . * 1000 | round / 1000 | tostring)" |
            if length > 9 then .[0:9] else . + (" " * ([9 - length, 0] | max)) end) as $pad_spend |

          # Budget
          (if .max_budget then "$\(.max_budget)/day" else "unlimited" end |
            if length > 11 then .[0:11] else . + (" " * ([11 - length, 0] | max)) end) as $pad_budget |

          # Models
          (if .models and (.models | length) > 0 then "restricted" else "all" end |
            if length > 9 then .[0:9] else . + (" " * ([9 - length, 0] | max)) end) as $pad_models |

          # Last active (relative)
          (if .last_active then
            (($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
             (.last_active | sub("\\.[0-9]+.*"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) |
            if . < 0 then "just now"
            elif . < 60 then "\(. | floor)s ago"
            elif . < 3600 then "\(. / 60 | floor)m ago"
            elif . < 86400 then "\(. / 3600 | floor)h ago"
            else "\(. / 86400 | floor)d ago"
            end
          else "never" end) as $last |

          "  \($pad_name)  \($pad_spend)  \($pad_budget)  \($pad_models)  \($last)"
        ),
        ""
      end'

    # Recent requests
    local count="$1"
    echo "$logs_data" | jq -r --argjson n "$count" '
      [.[] | select(.metadata.user_api_key_alias != null and .metadata.user_api_key_alias != "litellm-internal-health-check" and .model_group != "" and .model_group != null)] |
      sort_by(.startTime) | reverse | .[0:$n] |
      if length == 0 then
        "  Recent Requests",
        "  ────────────────────────────────────────────────────────────────────────────",
        "  No requests today.\n"
      else
        "  Recent Requests (today, newest first)",
        "  ────────────────────────────────────────────────────────────────────────────",
        (.[] |
          (.startTime | split("T")[1] | split(".")[0]) as $time |
          (.metadata.user_api_key_alias // "?") as $alias |
          ($alias | if length > 16 then .[0:16] else . + (" " * ([16 - length, 0] | max)) end) as $pad_alias |
          (.model_group // "?" | if length > 20 then .[0:20] else . + (" " * ([20 - length, 0] | max)) end) as $pad_model |
          (if .total_tokens > 0 then "\(.total_tokens)tok"
           else "image" end |
            if length > 8 then .[0:8] else . + (" " * ([8 - length, 0] | max)) end) as $pad_tokens |
          ("$\(.spend // 0 | . * 10000 | round / 10000 | tostring)" |
            if length > 8 then .[0:8] else . + (" " * ([8 - length, 0] | max)) end) as $pad_cost |
          ("\(.request_duration_ms // 0)ms") as $dur |
          "  \($time)  \($pad_alias)  \($pad_model)  \($pad_tokens)  \($pad_cost)  \($dur)"
        ),
        ""
      end'

    # Today summary
    echo "$logs_data" | jq -r '
      [.[] | select(.metadata.user_api_key_alias != null and .metadata.user_api_key_alias != "litellm-internal-health-check" and .model_group != "" and .model_group != null)] |
      if length == 0 then empty
      else
        "  Today: \(length) requests  ·  $\(map(.spend // 0) | add | . * 1000 | round / 1000) spent  ·  \(map(.total_tokens // 0) | add) tokens"
      end'
  }

  if [[ "$live" == "true" ]]; then
    # Check for tput
    if ! command -v tput &>/dev/null; then
      echo "ERROR: tput required for --live mode" >&2
      return 1
    fi
    trap 'tput cnorm; echo; exit 0' INT TERM
    tput civis  # hide cursor
    while true; do
      tput clear
      render_monitor "$log_count"
      if [[ "$live" == "true" ]]; then
        echo
        echo "  Refreshing every ${interval}s · Press Ctrl+C to stop"
      fi
      sleep "$interval"
    done
  else
    render_monitor "$log_count"
  fi
}

cmd_config_push() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Pushing config to instance $instance_id..."

  local config_b64
  config_b64=$(base64 "$CONFIG_DIR/litellm-config.yaml" | tr -d '\n')

  # Use JSON file for parameters to avoid shell quoting issues
  local params_file
  params_file=$(mktemp)
  trap 'rm -f "$params_file"' RETURN
  jq -n --arg b64 "$config_b64" \
    '{"commands":["echo \($b64) | base64 -d > /etc/litellm/config.yaml && chown litellm:litellm /etc/litellm/config.yaml && systemctl restart litellm && (systemctl restart rockport-video 2>/dev/null || true) && echo Config pushed and services restarted"]}' \
    > "$params_file"

  local instance_id region command_id
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --region "$region" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://$params_file" \
    --query "Command.CommandId" \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  echo "Waiting for restart..."
  if ! aws ssm wait command-executed \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" 2>/dev/null; then
    echo "WARNING: Wait timed out or command may have failed" >&2
  fi

  local result
  result=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" \
    --query "StandardOutputContent" \
    --output text)
  echo "$result"
}

cmd_logs() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Connecting to instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$(get_region)" \
    --document-name AWS-StartInteractiveCommand \
    --parameters '{"command":["sudo journalctl -u litellm -n 100 -f"]}'
}

cmd_deploy() {
  load_env
  echo "Deploying infrastructure..."
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  ensure_master_key "$region"
  ensure_state_backend

  cd "$TERRAFORM_DIR"
  terraform init -upgrade \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true"
  terraform apply

  echo
  echo "Deploy complete. Next steps:"
  echo "  ./scripts/rockport.sh status              # Verify health (wait ~5min for bootstrap)"
  echo "  ./scripts/rockport.sh key create <name>   # Create an API key"
  echo "  ./scripts/rockport.sh setup-claude         # Configure Claude Code"
}

cmd_destroy() {
  load_env
  echo "WARNING: This will destroy all Rockport infrastructure."
  read -rp "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi

  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  if ! aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    echo "No infrastructure found (state bucket '$bucket' does not exist). Nothing to destroy."
    return 0
  fi

  cd "$TERRAFORM_DIR"
  terraform init \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true"
  terraform destroy

  echo "Cleaning up SSM parameters..."
  aws ssm delete-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --region "$region" 2>/dev/null && echo "  Master key deleted." || echo "  Master key already removed."
  aws ssm delete-parameter \
    --name "/rockport/db-password" \
    --region "$region" 2>/dev/null && echo "  DB password deleted." || echo "  DB password already removed."
}

cmd_upgrade() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Restarting LiteLLM on instance $instance_id..."
  local result
  result=$(ssm_run "sudo systemctl restart litellm && (sudo systemctl restart rockport-video 2>/dev/null || true) && echo Services restarted successfully" 30)
  echo "$result"
}

cmd_start() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local state
  state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)

  if [[ "$state" == "running" ]]; then
    echo "Instance $instance_id is already running."
    wait_for_health "$(get_tunnel_url)" 30
    return
  fi

  echo "Starting instance $instance_id..."
  aws ec2 start-instances --instance-ids "$instance_id" --region "$region" > /dev/null
  echo "Waiting for running state..."
  aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"
  echo "Instance running. Waiting for services..."

  wait_for_health "$(get_tunnel_url)" 120
}

cmd_stop() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local state
  state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)

  if [[ "$state" == "stopped" ]]; then
    echo "Instance $instance_id is already stopped."
    return
  fi

  echo "Stopping instance $instance_id..."
  aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" > /dev/null
  echo "Waiting for stopped state..."
  aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$region"
  echo "Instance stopped."
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

usage() {
  cat <<EOF
Usage: rockport <command> [args]

Commands:
  init                Interactive setup — creates terraform.tfvars and master key
  deploy              Run terraform apply
  status              Check service health and model list
  models              List available models
  key create <name>   Create a new API key [--budget <amount>] [--claude-only]
  key list            List all API keys with spend
  key info <key>      Show key details and spend
  key revoke <key>    Revoke an API key
  spend               Summary: all-time total + current period by key
  spend keys          Spend breakdown by key (current budget period)
  monitor             Key status and recent requests [--live] [--interval N] [--count N]
  config push         Push local config to instance and restart
  logs                Stream LiteLLM logs (via SSM)
  upgrade             Restart LiteLLM service
  start               Start a stopped instance (waits for healthy)
  stop                Stop the instance (waits for stopped)
  setup-claude        Create key and show Claude Code config
  destroy             Run terraform destroy (with confirmation)
EOF
}

# All commands need these tools
check_dependencies

case "${1:-}" in
  init)     cmd_init ;;
  status)   cmd_status ;;
  key)
    case "${2:-}" in
      create) cmd_key_create "${@:3}" ;;
      list)   cmd_key_list ;;
      info)   cmd_key_info "${3:-}" ;;
      revoke) cmd_key_revoke "${3:-}" ;;
      *)      usage; exit 1 ;;
    esac
    ;;
  models)   cmd_models ;;
  spend)    cmd_spend "${@:2}" ;;
  config)
    case "${2:-}" in
      push) cmd_config_push ;;
      *)    usage; exit 1 ;;
    esac
    ;;
  monitor)      cmd_monitor "${@:2}" ;;
  logs)         cmd_logs ;;
  deploy)       cmd_deploy ;;
  destroy)      cmd_destroy ;;
  upgrade)      cmd_upgrade ;;
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  setup-claude) cmd_setup_claude ;;
  -h|--help|"") usage ;;
  *)            echo "Unknown command: $1"; echo; usage; exit 1 ;;
esac
