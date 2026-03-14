#!/bin/bash
set -euo pipefail

MASTER_KEY_SSM_PATH="/rockport/master-key"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
ENV_FILE="$TERRAFORM_DIR/.env"
CACHED_MASTER_KEY=""
CACHED_REGION=""

# --- Helper functions ---

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
  # Default
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
    --region "$(get_region)")
  echo "$CACHED_MASTER_KEY"
}

get_tunnel_url() {
  cd "$TERRAFORM_DIR"
  terraform output -raw tunnel_url 2>/dev/null
}

get_instance_id() {
  cd "$TERRAFORM_DIR"
  terraform output -raw instance_id 2>/dev/null
}

api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url
  url="$(get_tunnel_url)${path}"
  local key
  key="$(get_master_key)"

  if [[ -n "$data" ]]; then
    curl -s -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -s -X "$method" "$url" \
      -H "Authorization: Bearer $key"
  fi
}

get_state_bucket() {
  local region
  region="$(get_region)"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region")
  echo "rockport-tfstate-${account_id}-${region}"
}

ensure_state_backend() {
  local region bucket lock_table
  region="$(get_region)"
  bucket="$(get_state_bucket)"
  lock_table="rockport-tfstate-lock"

  # Create S3 bucket if it doesn't exist
  if ! aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    echo "Creating state bucket: $bucket"
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration LocationConstraint="$region"

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
  fi

  # Create DynamoDB lock table if it doesn't exist
  if ! aws dynamodb describe-table --table-name "$lock_table" --region "$region" 2>/dev/null | grep -q ACTIVE; then
    echo "Creating lock table: $lock_table"
    aws dynamodb create-table \
      --table-name "$lock_table" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$region"

    aws dynamodb wait table-exists --table-name "$lock_table" --region "$region"
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

  read -rp "AWS region [eu-west-2]: " region
  region="${region:-eu-west-2}"

  read -rp "Domain (e.g. llm.example.com): " domain
  [[ -z "$domain" ]] && { echo "Domain is required."; exit 1; }

  read -rp "Cloudflare Zone ID: " cf_zone_id
  [[ -z "$cf_zone_id" ]] && { echo "Zone ID is required."; exit 1; }

  read -rp "Cloudflare Account ID: " cf_account_id
  [[ -z "$cf_account_id" ]] && { echo "Account ID is required."; exit 1; }

  read -rp "Cloudflare API Token: " cf_api_token
  [[ -z "$cf_api_token" ]] && { echo "API Token is required."; exit 1; }

  read -rp "Budget alert email: " email
  [[ -z "$email" ]] && { echo "Email is required."; exit 1; }

  local subdomain
  subdomain="${domain%%.*}"

  # Save Cloudflare API token to .env (gitignored, sourced automatically)
  cat > "$ENV_FILE" <<EOF
export CLOUDFLARE_API_TOKEN="$cf_api_token"
EOF
  chmod 600 "$ENV_FILE"
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
  echo "Written to terraform/terraform.tfvars"

  echo
  echo "Checking for master key in SSM..."
  if aws ssm get-parameter --name "$MASTER_KEY_SSM_PATH" --region "$region" &>/dev/null 2>&1; then
    echo "Master key already exists in SSM."
  else
    local master_key="sk-$(openssl rand -hex 24)"
    aws ssm put-parameter \
      --name "$MASTER_KEY_SSM_PATH" \
      --value "$master_key" \
      --type SecureString \
      --region "$region"
    echo "Master key created in SSM."
  fi

  echo
  echo "Creating Terraform state backend..."
  ensure_state_backend

  echo
  echo "Next steps:"
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
  local url
  url="$(get_tunnel_url)"
  echo "Checking health at $url..."
  local key
  key="$(get_master_key)"
  curl -s -H "Authorization: Bearer $key" "$url/health" | python3 -c "
import sys,json
d=json.load(sys.stdin)
h=[m.get('model','?') for m in d.get('healthy_endpoints',[])]
u=[m.get('model','?') for m in d.get('unhealthy_endpoints',[])]
print(f'Healthy ({len(h)}):')
for m in h: print(f'  ✓ {m}')
if u:
  print(f'Unhealthy ({len(u)}):')
  for m in u: print(f'  ✗ {m}')
" 2>/dev/null || echo "Could not reach health endpoint"
}

cmd_key_create() {
  local name="${1:?Usage: rockport key create <name> [--budget <amount>]}"
  shift
  local budget=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --budget) budget="${2:?--budget requires a dollar amount}"; shift 2 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  local payload="{\"key_alias\": \"$name\""
  if [[ -n "$budget" ]]; then
    payload+=", \"max_budget\": $budget, \"budget_duration\": \"1d\""
  fi
  payload+="}"

  echo "Creating key '$name'..."
  local response
  response=$(api_call POST "/key/generate" "$payload")

  local key
  key=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))")

  echo "$response" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"Key:    {d.get('key','?')}\")
print(f\"Name:   {d.get('key_alias','?')}\")
print(f\"ID:     {d.get('token','?')}\")
budget=d.get('max_budget')
if budget: print(f\"Budget: \${budget}/day\")
"

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
  api_call GET "/key/list?return_full_object=true" | python3 -c "
import sys,json
data=json.load(sys.stdin)
keys=data.get('keys',[]) if isinstance(data,dict) else data
if not keys:
  print('  No keys found')
  sys.exit()
for k in keys:
  if isinstance(k,str): continue
  name=k.get('key_alias') or k.get('key_name','unnamed')
  token=k.get('token','?')[:8]+'...'
  spend=k.get('spend',0) or 0
  budget=k.get('max_budget')
  limit=f'  (limit: \${budget}/day)' if budget else ''
  print(f'  {name:<20} {token}  \${spend:.4f}{limit}')
"
}

cmd_key_info() {
  local key="${1:?Usage: rockport key info <key>}"
  api_call GET "/key/info?key=$key" | python3 -c "
import sys,json
d=json.load(sys.stdin)
info=d.get('info',d)
name=info.get('key_alias') or info.get('key_name','?')
print(f\"Name:      {name}\")
print(f\"Spend:     \${info.get('spend',0) or 0:.4f}\")
print(f\"Max Budget:{' $'+str(info.get('max_budget')) if info.get('max_budget') else ' unlimited'}\")
print(f\"Created:   {info.get('created_at','?')}\")
print(f\"Expires:   {info.get('expires','never')}\")
rpm=info.get('rpm_limit')
tpm=info.get('tpm_limit')
if rpm: print(f\"RPM Limit: {rpm}\")
if tpm: print(f\"TPM Limit: {tpm}\")
"
}

cmd_key_revoke() {
  local key="${1:?Usage: rockport key revoke <key>}"
  echo "Revoking key..."
  api_call POST "/key/delete" "{\"keys\": [\"$key\"]}" | python3 -m json.tool
}

cmd_models() {
  echo "Listing models..."
  api_call GET "/v1/models" | python3 -c "
import sys,json
d=json.load(sys.stdin)
models=d.get('data',[])
for m in sorted(models, key=lambda x: x.get('id','')):
  print(f\"  {m.get('id','?')}\")
print(f'\n{len(models)} models available')
"
}

cmd_spend() {
  local subcmd="${1:-}"

  case "$subcmd" in
    keys)
      echo "Spend by key..."
      api_call GET "/key/list?return_full_object=true" | python3 -c "
import sys,json
data=json.load(sys.stdin)
keys=data.get('keys',[]) if isinstance(data,dict) else data
keys=[k for k in keys if isinstance(k,dict)]
if not keys:
  print('  No keys found')
  sys.exit()
keys.sort(key=lambda k: k.get('spend',0) or 0, reverse=True)
total=0
for k in keys:
  name=k.get('key_alias') or k.get('key_name','unnamed')
  spend=k.get('spend',0) or 0
  total+=spend
  print(f'  {name:<20} \${spend:.4f}')
print(f'\n  Total: \${total:.4f}')
"
      ;;
    *)
      echo "Global spend..."
      api_call GET "/global/spend" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d, list):
  total=sum(r.get('spend',0) or 0 for r in d)
  print(f'Total spend: \${total:.4f}')
  for r in d:
    if r.get('api_key'):
      name=r.get('key_name','?')
      spend=r.get('spend',0) or 0
      print(f'  {name:<20} \${spend:.4f}')
else:
  spend=d.get('spend',0) or 0
  print(f'Total spend: \${spend:.4f}')
" 2>/dev/null || echo "Could not fetch spend data"
      ;;
  esac
}

cmd_config_push() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Pushing config to instance $instance_id..."

  # Use send-command instead of start-session to avoid config appearing in session history.
  # The config is passed via stdin-style base64 in the command array, which SSM encrypts
  # in transit and does not persist in session manager logs.
  local config_b64
  config_b64=$(base64 -w0 "$CONFIG_DIR/litellm-config.yaml")

  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --region "$region" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo '$config_b64' | base64 -d > /etc/litellm/config.yaml && chown litellm:litellm /etc/litellm/config.yaml && systemctl restart litellm && echo 'Config pushed and LiteLLM restarted'\"]" \
    --query "Command.CommandId" \
    --output text)

  echo "Command sent (ID: $command_id). Waiting for result..."
  aws ssm wait command-executed \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" 2>/dev/null || true

  aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" \
    --query "[Status, StandardOutputContent]" \
    --output text
}

cmd_logs() {
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
    -backend-config="dynamodb_table=rockport-tfstate-lock"
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

  local region
  region="$(get_region)"

  cd "$TERRAFORM_DIR"
  terraform destroy

  # Clean up SSM master key (created outside terraform by init)
  echo "Cleaning up SSM master key..."
  aws ssm delete-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --region "$region" 2>/dev/null && echo "Master key deleted." || echo "Master key already removed."
}

cmd_upgrade() {
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
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Stopping instance $instance_id..."
  aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" > /dev/null
  echo "Instance stopping."
}

cmd_setup_claude() {
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
