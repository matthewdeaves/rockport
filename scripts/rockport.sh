#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# (`source-path=SCRIPTDIR` tells shellcheck to resolve `source $SCRIPT_DIR/lib/*.sh`
# directives relative to this file's directory, silencing SC1091 in CI.)

die() { echo "ERROR: $*" >&2; exit 1; }

MASTER_KEY_SSM_PATH="/rockport/master-key"
# Use BASH_SOURCE so SCRIPT_DIR resolves to scripts/ even when sourced (e.g.
# from tests/auth-flow-test.sh). $0 falls back to "bash" when sourced via
# `bash -c 'source ...'`, breaking the relative cd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)" || { echo "ERROR: terraform/ directory not found" >&2; exit 1; }
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "ERROR: config/ directory not found" >&2; exit 1; }
ENV_FILE="$TERRAFORM_DIR/.env"
# CACHED_REGION is used by get_region() in this file; the other cache vars
# moved to their owning lib (state.sh, api.sh, ssm.sh) in 019.
CACHED_REGION=""

# Anthropic model names for Claude Code key restrictions.
# Derived from config/litellm-config.yaml at invocation time so that every
# `- model_name: claude-*` entry is automatically included — no drift risk
# when new Claude models are added. Fails hard if the config is missing or
# has zero matches (prevents silent creation of "Claude-only" keys with no
# Claude access). Spec 016 FR-006.

# --- Core helpers (used by lib/*.sh) ---

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

# --- Sourced libs (019 split) ---

source "$SCRIPT_DIR/lib/api.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/iam.sh"
source "$SCRIPT_DIR/lib/auth.sh"
source "$SCRIPT_DIR/lib/ssm.sh"
source "$SCRIPT_DIR/lib/keys.sh"
source "$SCRIPT_DIR/lib/spend.sh"
source "$SCRIPT_DIR/lib/diag.sh"

# --- Bootstrap + lifecycle entry points (stay in rockport.sh) ---

cmd_init() {
  # init manages IAM policies that require admin permissions.
  # If the auto-profile selected the deployer, unset it so we fall back
  # to the default/admin credentials. The deployer profile gets created
  # (or reused) at the end of init via ensure_deployer_access().
  if [[ "${AWS_PROFILE:-}" == "rockport" ]]; then
    unset AWS_PROFILE
  fi

  echo "Rockport Setup"
  echo "=============="
  echo

  for cmd in aws terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found. Run ./scripts/setup.sh first."
      exit 1
    fi
  done

  # 018: every admin operation requires an MFA-derived session. The
  # RockportAdmin policy explicit-denies all actions outside a small
  # safe-list (sts:GetSessionToken, MFA management, self-introspection)
  # when aws:MultiFactorAuthPresent is false. admin_mfa_session() mints
  # the session via sts:GetSessionToken and exports AWS_PROFILE.
  admin_mfa_session

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

cmd_deploy() {
  load_env
  echo "Deploying infrastructure..."
  local region bucket enable_guardrails=""
  # Parse --guardrails flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --guardrails)    enable_guardrails="-var=enable_guardrails=true"; shift ;;
      --no-guardrails) enable_guardrails="-var=enable_guardrails=false"; shift ;;
      *) shift ;;
    esac
  done
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  ensure_master_key "$region"
  ensure_state_backend

  # Ensure artifacts bucket exists before uploading
  local artifacts_bucket
  artifacts_bucket="$(get_artifacts_bucket)"
  if ! aws s3api head-bucket --bucket "$artifacts_bucket" --region "$region" 2>/dev/null; then
    echo "  Creating artifacts bucket (first deploy)..."
    # Terraform will create it properly; do a minimal create for the upload
    aws s3api create-bucket --bucket "$artifacts_bucket" --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" --no-cli-pager \
      || die "Failed to create artifacts bucket"
    aws s3api put-public-access-block --bucket "$artifacts_bucket" --region "$region" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "Failed to set public access block on artifacts bucket"
  fi

  # Package and upload deploy artifact to S3 (before terraform apply)
  package_and_upload_artifact

  cd "$TERRAFORM_DIR" || die "Failed to cd to terraform directory"
  terraform init -upgrade \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true" \
    || die "terraform init failed"

  # Import artifacts bucket into state if pre-created by this script
  if ! terraform state show aws_s3_bucket.artifacts &>/dev/null; then
    echo "  Importing artifacts bucket into Terraform state..."
    terraform import aws_s3_bucket.artifacts "$artifacts_bucket" || die "Failed to import artifacts bucket"
  fi

  # Import orphaned CloudWatch log group if it exists from a previous deploy
  # (Lambda auto-creates this log group; terraform destroy removes the Lambda but not the log group)
  if ! terraform state show 'aws_cloudwatch_log_group.idle_shutdown[0]' &>/dev/null; then
    local log_group_check
    log_group_check=$(aws logs describe-log-groups --log-group-name-prefix /aws/lambda/rockport-idle-shutdown --region "$region" \
        --query 'logGroups[0].logGroupName' --output text 2>/dev/null) || log_group_check=""
    if echo "$log_group_check" | grep -q rockport; then
      echo "  Importing existing idle-shutdown log group into Terraform state..."
      terraform import 'aws_cloudwatch_log_group.idle_shutdown[0]' '/aws/lambda/rockport-idle-shutdown'
    fi
  fi

  # shellcheck disable=SC2086
  terraform apply $enable_guardrails || die "terraform apply failed"

  # Auto-configure guardrails in litellm-config.yaml if deployed with --guardrails
  if [[ -n "$enable_guardrails" && "$enable_guardrails" == *"true"* ]]; then
    local guardrail_id
    guardrail_id=$(terraform output -raw guardrail_id 2>/dev/null) || guardrail_id=""
    if [[ -n "$guardrail_id" ]]; then
      local config_file="$CONFIG_DIR/litellm-config.yaml"
      # Check if guardrails section is currently commented out
      if grep -q '^# guardrails:' "$config_file"; then
        echo "  Enabling guardrails in config (ID: $guardrail_id)..."
        sed -i 's/^# guardrails:/guardrails:/' "$config_file"
        sed -i 's/^#   - guardrail_name:/  - guardrail_name:/' "$config_file"
        sed -i 's/^#     litellm_params:/    litellm_params:/' "$config_file"
        sed -i 's/^#       guardrail: bedrock/      guardrail: bedrock/' "$config_file"
        sed -i 's/^#       mode:/      mode:/' "$config_file"
        sed -i "s/^#       guardrailIdentifier:.*/      guardrailIdentifier: \"$guardrail_id\"/" "$config_file"
        sed -i 's/^#       guardrailVersion:/      guardrailVersion:/' "$config_file"
        sed -i 's/^#       aws_region_name:/      aws_region_name:/' "$config_file"
        sed -i 's/^#       default_on:/      default_on:/' "$config_file"
        sed -i 's/^#       mask_request_content:/      mask_request_content:/' "$config_file"
        sed -i 's/^#       mask_response_content:/      mask_response_content:/' "$config_file"
      elif grep -q 'guardrailIdentifier:' "$config_file"; then
        echo "  Updating guardrail ID in config ($guardrail_id)..."
        sed -i "s/guardrailIdentifier: .*/guardrailIdentifier: \"$guardrail_id\"/" "$config_file"
      fi
    fi
  fi

  # Comment out guardrails config when deploying without --guardrails (clean state)
  if [[ -n "$enable_guardrails" && "$enable_guardrails" == *"false"* ]]; then
    local config_file="$CONFIG_DIR/litellm-config.yaml"
    if grep -q '^guardrails:' "$config_file"; then
      echo "  Disabling guardrails in config..."
      sed -i 's/^guardrails:/# guardrails:/' "$config_file"
      sed -i 's/^  - guardrail_name:/#   - guardrail_name:/' "$config_file"
      sed -i 's/^    litellm_params:/#     litellm_params:/' "$config_file"
      sed -i 's/^      guardrail: bedrock/#       guardrail: bedrock/' "$config_file"
      sed -i 's/^      mode:/#       mode:/' "$config_file"
      sed -i 's/^      guardrailIdentifier:/#       guardrailIdentifier:/' "$config_file"
      sed -i 's/^      guardrailVersion:/#       guardrailVersion:/' "$config_file"
      sed -i 's/^      aws_region_name:/#       aws_region_name:/' "$config_file"
      sed -i 's/^      default_on:/#       default_on:/' "$config_file"
      sed -i 's/^      mask_request_content:/#       mask_request_content:/' "$config_file"
      sed -i 's/^      mask_response_content:/#       mask_response_content:/' "$config_file"
    fi
  fi

  echo
  echo "Deploy complete. Next steps:"
  echo "  ./scripts/rockport.sh status              # Verify health (wait ~5min for bootstrap)"
  echo "  ./scripts/rockport.sh key create <name>   # Create an API key"
  echo "  ./scripts/rockport.sh setup-claude         # Configure Claude Code"
}

cmd_destroy() {
  # 021: destroy runs under admin (not deploy) so terraform doesn't kill its
  # own STS session by deleting aws_iam_role.operator_deploy mid-run, and so
  # iam:DeletePolicy on the operator boundary policies works (the deploy
  # boundary explicit-denies that action). See SUBCOMMAND_ROLE comment.
  admin_mfa_session

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

  cd "$TERRAFORM_DIR" || die "Failed to cd to terraform directory"
  terraform init \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true" \
    || die "terraform init failed"
  terraform destroy || die "terraform destroy failed"

  # Comment out guardrails config if it was active (guardrail resource is now destroyed)
  local config_file="$CONFIG_DIR/litellm-config.yaml"
  if grep -q '^guardrails:' "$config_file"; then
    echo "  Commenting out guardrails config (resource destroyed)..."
    sed -i 's/^guardrails:/# guardrails:/' "$config_file"
    sed -i 's/^  - guardrail_name:/#   - guardrail_name:/' "$config_file"
    sed -i 's/^    litellm_params:/#     litellm_params:/' "$config_file"
    sed -i 's/^      guardrail: bedrock/#       guardrail: bedrock/' "$config_file"
    sed -i 's/^      mode:/#       mode:/' "$config_file"
    sed -i 's/^      guardrailIdentifier:/#       guardrailIdentifier:/' "$config_file"
    sed -i 's/^      guardrailVersion:/#       guardrailVersion:/' "$config_file"
    sed -i 's/^      aws_region_name:/#       aws_region_name:/' "$config_file"
    sed -i 's/^      default_on:/#       default_on:/' "$config_file"
    sed -i 's/^      mask_request_content:/#       mask_request_content:/' "$config_file"
    sed -i 's/^      mask_response_content:/#       mask_response_content:/' "$config_file"
  fi

  echo "Cleaning up orphaned resources..."
  aws logs delete-log-group \
    --log-group-name "/aws/lambda/rockport-idle-shutdown" \
    --region "$region" 2>/dev/null && echo "  Lambda log group deleted." || echo "  Lambda log group already removed."

  echo "Cleaning up SSM parameters..."
  aws ssm delete-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --region "$region" 2>/dev/null && echo "  Master key deleted." || echo "  Master key already removed."
  aws ssm delete-parameter \
    --name "/rockport/db-password" \
    --region "$region" 2>/dev/null && echo "  DB password deleted." || echo "  DB password already removed."
}

usage() {
  cat <<EOF
Usage: rockport <command> [args]

Commands:
  init                Interactive setup — creates terraform.tfvars and master key
  auth                Authenticate via MFA-gated STS [--role readonly|runtime-ops|deploy]
  auth status         Show cached operator-role sessions and time remaining
  deploy              Run terraform apply [--guardrails] [--no-guardrails]
  status [--instance] Check service health and model list (--instance: includes in-VM stats; escalates to runtime-ops)
  models              List available models
  key create <name>   Create a new API key [--budget <amount>] [--claude-only]
  key list            List all API keys with spend
  key info <key>      Show key details and spend
  key revoke <key>    Revoke an API key
  spend               Combined infra + model usage summary
  spend keys          Spend breakdown by key with budgets and creation dates
  spend models        Spend breakdown by model with request/token counts
  spend daily [N]     Daily spend for last N days (default 30)
  spend today         Today's spend grouped by key and model
  spend infra [N]     AWS infrastructure costs for last N months (default 3)
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

# 017: resolve the right operator role for this subcommand and ensure the
# AWS_PROFILE points at a fresh STS session before any AWS API calls. Skipped
# when ROCKPORT_AUTH_DISABLED=1 (first-ever bootstrap escape hatch).
case "${1:-}" in
  -h|--help|"") : ;;
  *) _ensure_role_for_subcommand "${1:-}" "${@:2}" ;;
esac

# Pre-cache CF Access credentials for commands that make API calls
case "${1:-}" in
  status|key|models|spend|monitor|setup-claude)
    load_env
    ensure_cf_access_cached
    ;;
esac

case "${1:-}" in
  init)     cmd_init ;;
  auth)     cmd_auth "${@:2}" ;;
  status)   cmd_status "${@:2}" ;;
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
  deploy)       cmd_deploy "${@:2}" ;;
  destroy)      cmd_destroy ;;
  upgrade)      cmd_upgrade ;;
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  setup-claude) cmd_setup_claude ;;
  -h|--help|"") usage ;;
  *)            echo "Unknown command: $1"; echo; usage; exit 1 ;;
esac
