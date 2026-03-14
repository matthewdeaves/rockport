#!/bin/bash
set -euo pipefail

MASTER_KEY_SSM_PATH="/rockport/master-key"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)" || { echo "ERROR: terraform/ directory not found" >&2; exit 1; }
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "ERROR: config/ directory not found" >&2; exit 1; }
ENV_FILE="$TERRAFORM_DIR/.env"
CACHED_MASTER_KEY=""
CACHED_REGION=""

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
  # Try terraform.tfvars first (no terraform state needed)
  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    local r
    r=$(grep -oP 'region\s*=\s*"\K[^"]+' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) && {
      CACHED_REGION="$r"
      echo "$r"
      return
    }
  fi
  # Try terraform output
  local r
  r=$(cd "$TERRAFORM_DIR" && terraform output -raw region 2>/dev/null) && {
    CACHED_REGION="$r"
    echo "$r"
    return
  }
  # Default — warn user
  echo "WARNING: Could not determine region from terraform. Using default: eu-west-2" >&2
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
  local result
  result=$(cd "$TERRAFORM_DIR" && terraform output -raw tunnel_url 2>&1) || {
    echo "ERROR: Failed to get tunnel_url from terraform. Run './scripts/rockport.sh deploy' first." >&2
    return 1
  }
  echo "$result"
}

get_instance_id() {
  local result
  result=$(cd "$TERRAFORM_DIR" && terraform output -raw instance_id 2>&1) || {
    echo "ERROR: Failed to get instance_id from terraform. Run './scripts/rockport.sh deploy' first." >&2
    return 1
  }
  echo "$result"
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
      -d "$data")
  else
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" \
      -H "Authorization: Bearer $key")
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

ensure_deployer_access() {
  local deployer_user="rockport-deployer"
  local policy_name="RockportDeployerAccess"
  local policy_file="$TERRAFORM_DIR/rockport-deployer-policy.json"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)
  local policy_arn="arn:aws:iam::${account_id}:policy/${policy_name}"

  # Create or update the IAM policy
  if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null; then
    local versions
    versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
    for v in $versions; do
      aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$v" 2>/dev/null || true
    done
    aws iam create-policy-version \
      --policy-arn "$policy_arn" \
      --policy-document "file://$policy_file" \
      --set-as-default >/dev/null
    echo "  IAM policy ........... updated ($policy_name)"
  else
    aws iam create-policy \
      --policy-name "$policy_name" \
      --policy-document "file://$policy_file" >/dev/null
    echo "  IAM policy ........... created ($policy_name)"
  fi

  # Create the deployer user if it doesn't exist
  if aws iam get-user --user-name "$deployer_user" &>/dev/null; then
    echo "  IAM user ............. ok ($deployer_user)"
  else
    aws iam create-user --user-name "$deployer_user" >/dev/null
    echo "  IAM user ............. created ($deployer_user)"
  fi

  # Attach the policy to the deployer user
  if aws iam list-attached-user-policies --user-name "$deployer_user" \
    --query "AttachedPolicies[?PolicyArn=='$policy_arn']" --output text 2>/dev/null | grep -q "$policy_name"; then
    echo "  Policy attachment .... ok (already on $deployer_user)"
  else
    aws iam attach-user-policy --user-name "$deployer_user" --policy-arn "$policy_arn"
    echo "  Policy attachment .... attached to $deployer_user"
  fi

  # Check if the deployer user has access keys — if not, create them
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

    # Configure the AWS CLI profile automatically
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

  # Create S3 bucket if it doesn't exist
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

      if aws ssm get-parameter --name "$MASTER_KEY_SSM_PATH" --region "$region" &>/dev/null 2>&1; then
        echo "  Master key ........... ok (exists in SSM)"
      else
        local master_key
        master_key="sk-$(openssl rand -hex 24)"
        aws ssm put-parameter \
          --name "$MASTER_KEY_SSM_PATH" \
          --value "$master_key" \
          --type SecureString \
          --region "$region"
        echo "  Master key ........... created in SSM"
      fi

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

  # Save Cloudflare API token to .env (gitignored, sourced automatically)
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

  if aws ssm get-parameter --name "$MASTER_KEY_SSM_PATH" --region "$region" &>/dev/null 2>&1; then
    echo "  Master key ........... ok (exists in SSM)"
  else
    local master_key
    master_key="sk-$(openssl rand -hex 24)"
    aws ssm put-parameter \
      --name "$MASTER_KEY_SSM_PATH" \
      --value "$master_key" \
      --type SecureString \
      --region "$region"
    echo "  Master key ........... created in SSM"
  fi

  ensure_state_backend

  echo
  echo "Setup complete. Next steps:"
  echo "  1. Enable Bedrock model access in the AWS Console ($region)"
  if [[ "$region" != eu-* ]]; then
    echo "  2. Update model prefixes in config/litellm-config.yaml"
    echo "     (remove 'eu.' prefix for non-EU regions)"
    echo "  3. Run: ./scripts/rockport.sh deploy"
  else
    echo "  2. Run: ./scripts/rockport.sh deploy"
  fi
}

cmd_status() {
  check_dependencies
  local url
  url="$(get_tunnel_url)"
  echo "Checking health at $url..."
  local response
  response=$(api_call GET "/health") || { echo "Could not reach health endpoint"; return 1; }

  local healthy unhealthy count
  healthy=$(echo "$response" | jq -r '.healthy_endpoints[]?.model // empty')
  unhealthy=$(echo "$response" | jq -r '.unhealthy_endpoints[]?.model // empty')

  count=$(echo "$healthy" | grep -c . 2>/dev/null || true)
  echo "Healthy ($count):"
  echo "$healthy" | while IFS= read -r m; do
    [[ -n "$m" ]] && echo "  ✓ $m"
  done

  if [[ -n "$unhealthy" ]]; then
    count=$(echo "$unhealthy" | grep -c . 2>/dev/null || true)
    echo "Unhealthy ($count):"
    echo "$unhealthy" | while IFS= read -r m; do
      [[ -n "$m" ]] && echo "  ✗ $m"
    done
  fi
}

cmd_key_create() {
  check_dependencies
  local name="${1:?Usage: rockport key create <name> [--budget <amount>]}"
  shift
  local budget=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --budget) budget="${2:?--budget requires a dollar amount}"; shift 2 ;;
      *) echo "Unknown option: $1. See: rockport key create <name> [--budget <amount>]"; exit 1 ;;
    esac
  done

  # Check for duplicate key name
  local existing
  existing=$(api_call GET "/key/list?return_full_object=true" 2>/dev/null || true)
  if [[ -n "$existing" ]] && echo "$existing" | jq -e ".keys[]? | select(.key_alias == \"$name\")" > /dev/null 2>&1; then
    echo "ERROR: A key with name '$name' already exists. Choose a different name." >&2
    return 1
  fi

  local payload="{\"key_alias\": \"$name\""
  if [[ -n "$budget" ]]; then
    payload+=", \"max_budget\": $budget, \"budget_duration\": \"1d\""
  fi
  payload+="}"

  echo "Creating key '$name'..."
  local response
  response=$(api_call POST "/key/generate" "$payload")

  local key
  key=$(echo "$response" | jq -r '.key // empty')

  echo "$response" | jq -r '"Key:    \(.key // "?")\nName:   \(.key_alias // "?")\nID:     \(.token // "?")" + (if .max_budget then "\nBudget: $\(.max_budget)/day" else "" end)'

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
  check_dependencies
  echo "Listing keys..."
  local response
  response=$(api_call GET "/key/list?return_full_object=true")

  echo "$response" | jq -r '
    (.keys // .) as $keys |
    if ($keys | length) == 0 then "  No keys found"
    else $keys[] | select(type == "object") |
      "\((.key_alias // .key_name // "unnamed") | . + (" " * (20 - length)))\(.token[:8])...  $\(.spend // 0 | tostring | .[0:6])\(if .max_budget then "  (limit: $\(.max_budget)/day)" else "" end)"
    end'
}

cmd_key_info() {
  check_dependencies
  local key="${1:?Usage: rockport key info <key>}"
  local response
  response=$(api_call GET "/key/info?key=$key")

  echo "$response" | jq -r '
    (.info // .) as $i |
    "Name:      \($i.key_alias // $i.key_name // "?")\nSpend:     $\($i.spend // 0)\nMax Budget:\(if $i.max_budget then " $\($i.max_budget)" else " unlimited" end)\nCreated:   \($i.created_at // "?")\nExpires:   \($i.expires // "never")" +
    (if $i.rpm_limit then "\nRPM Limit: \($i.rpm_limit)" else "" end) +
    (if $i.tpm_limit then "\nTPM Limit: \($i.tpm_limit)" else "" end)'
}

cmd_key_revoke() {
  check_dependencies
  local key="${1:?Usage: rockport key revoke <key>}"
  echo "Revoking key..."
  api_call POST "/key/delete" "{\"keys\": [\"$key\"]}" | jq .
}

cmd_models() {
  check_dependencies
  echo "Listing models..."
  local response
  response=$(api_call GET "/v1/models")

  echo "$response" | jq -r '.data | sort_by(.id)[] | "  \(.id)"'
  echo
  echo "$response" | jq -r '"\(.data | length) models available"'
}

cmd_spend() {
  check_dependencies
  local subcmd="${1:-}"

  case "$subcmd" in
    keys)
      echo "Spend by key..."
      local response
      response=$(api_call GET "/key/list?return_full_object=true")

      echo "$response" | jq -r '
        (.keys // .) | map(select(type == "object")) |
        if length == 0 then "  No keys found"
        else sort_by(.spend // 0) | reverse | . as $keys |
          ($keys[] | "  \((.key_alias // .key_name // "unnamed") | . + (" " * (20 - length)))$\(.spend // 0 | tostring | .[0:6])"),
          "",
          "  Total: $\($keys | map(.spend // 0) | add | tostring | .[0:6])"
        end'
      ;;
    *)
      echo "Global spend..."
      local response
      response=$(api_call GET "/global/spend") || { echo "Could not fetch spend data"; return 1; }

      echo "$response" | jq -r '
        if type == "array" then
          "Total spend: $\(map(.spend // 0) | add)" +
          (map(select(.api_key)) | if length > 0 then
            "\n" + (map("  \((.key_name // "?") | . + (" " * (20 - length)))$\(.spend // 0)") | join("\n"))
          else "" end)
        else "Total spend: $\(.spend // 0)"
        end'
      ;;
  esac
}

cmd_config_push() {
  check_dependencies
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Pushing config to instance $instance_id..."

  local config_b64
  config_b64=$(base64 -w0 "$CONFIG_DIR/litellm-config.yaml")

  # Use JSON file for parameters to avoid shell injection via quoting issues
  local params_file
  params_file=$(mktemp)
  trap 'rm -f "$params_file"' RETURN
  jq -n --arg b64 "$config_b64" \
    '{"commands":["echo \($b64) | base64 -d > /etc/litellm/config.yaml && chown litellm:litellm /etc/litellm/config.yaml && systemctl restart litellm && echo Config pushed and LiteLLM restarted"]}' \
    > "$params_file"

  local command_id
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

  echo "Command sent (ID: $command_id). Waiting for result..."
  if ! aws ssm wait command-executed \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" 2>/dev/null; then
    echo "WARNING: Wait timed out or command may have failed" >&2
  fi

  aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" \
    --query "[Status, StandardOutputContent]" \
    --output text
}

cmd_logs() {
  check_dependencies
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Connecting to instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$(get_region)" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="journalctl -u litellm -n 100 -f"
}

cmd_deploy() {
  check_dependencies
  load_env
  echo "Deploying infrastructure..."
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

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
  check_dependencies
  load_env
  echo "WARNING: This will destroy all Rockport infrastructure."
  read -rp "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi

  local region
  region="$(get_region)"

  local bucket
  bucket="$(get_state_bucket)"

  # If the state bucket doesn't exist, there's nothing to destroy
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

  # Clean up SSM parameters (created outside terraform by init/bootstrap)
  echo "Cleaning up SSM parameters..."
  aws ssm delete-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --region "$region" 2>/dev/null && echo "Master key deleted." || echo "Master key already removed."
  aws ssm delete-parameter \
    --name "/rockport/db-password" \
    --region "$region" 2>/dev/null && echo "DB password deleted." || echo "DB password already removed."
}

cmd_upgrade() {
  check_dependencies
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Restarting LiteLLM on instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$(get_region)" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="sudo systemctl restart litellm && echo 'LiteLLM restarted successfully'"
}

cmd_start() {
  check_dependencies
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Starting instance $instance_id..."
  aws ec2 start-instances --instance-ids "$instance_id" --region "$region" > /dev/null
  echo "Waiting for running state..."
  aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"
  echo "Instance running. Services will be ready in ~60 seconds."
}

cmd_stop() {
  check_dependencies
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Stopping instance $instance_id..."
  aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" > /dev/null
  echo "Instance stopping."
}

cmd_setup_claude() {
  check_dependencies
  local key_name
  read -rp "Key name [claude-code]: " key_name
  key_name="${key_name:-claude-code}"

  # Delegates to key create which generates the settings file
  cmd_key_create "$key_name"

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
  key create <name>   Create a new API key [--budget <amount>]
  key list            List all API keys with spend
  key info <key>      Show key details and spend
  key revoke <key>    Revoke an API key
  spend [keys]        Show global spend (or breakdown by key)
  config push         Push local config to instance and restart
  logs                Stream LiteLLM logs (via SSM)
  upgrade             Restart LiteLLM service
  start               Start a stopped instance
  stop                Stop the instance
  setup-claude        Create key and show Claude Code config
  destroy             Run terraform destroy (with confirmation)
EOF
}

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
  spend)    cmd_spend "${2:-}" ;;
  config)
    case "${2:-}" in
      push) cmd_config_push ;;
      *)    usage; exit 1 ;;
    esac
    ;;
  logs)         cmd_logs ;;
  deploy)       cmd_deploy ;;
  destroy)      cmd_destroy ;;
  upgrade)      cmd_upgrade ;;
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  setup-claude) cmd_setup_claude ;;
  *)            usage; exit 1 ;;
esac
