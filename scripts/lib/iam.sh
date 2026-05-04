# shellcheck shell=bash
# scripts/lib/iam.sh — IAM policy + deployer-user lifecycle helpers used by
# `init`. Sourced by rockport.sh. Relies on die(), get_region(), load_env().

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
      --set-as-default >/dev/null || die "Failed to update IAM policy $name"
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

  local attached
  attached=$(aws iam list-attached-user-policies --user-name "$user" \
    --query "AttachedPolicies[?PolicyArn=='$arn']" --output text 2>/dev/null) || attached=""
  if echo "$attached" | grep -q "$name"; then
    echo "  Policy attachment .... ok ($name → $user)"
  else
    aws iam attach-user-policy --user-name "$user" --policy-arn "$arn" \
      || die "Failed to attach policy $name to $user"
    echo "  Policy attachment .... attached ($name → $user)"
  fi
}

# Detach an IAM policy from a user if currently attached. Idempotent —
# silently no-op when the user doesn't exist or the policy isn't attached.
detach_iam_policy() {
  local user="$1" name="$2" account_id="$3" reason="${4:-}"
  local arn="arn:aws:iam::${account_id}:policy/${name}"

  aws iam get-user --user-name "$user" &>/dev/null || return 0
  local attached
  attached=$(aws iam list-attached-user-policies --user-name "$user" \
    --query "AttachedPolicies[?PolicyArn=='$arn']" --output text 2>/dev/null) || attached=""
  if echo "$attached" | grep -q "$name"; then
    aws iam detach-user-policy --user-name "$user" --policy-arn "$arn" \
      || die "Failed to detach policy $name from $user"
    if [[ -n "$reason" ]]; then
      echo "  Policy attachment .... detached ($name → $user, $reason)"
    else
      echo "  Policy attachment .... detached ($name → $user)"
    fi
  fi
}

ensure_deployer_access() {
  local deployer_user="rockport-deployer"
  local policy_dir="$TERRAFORM_DIR/deployer-policies"
  local account_id caller_user
  local caller_identity
  caller_identity=$(aws sts get-caller-identity --output json) \
    || die "Failed to get caller identity"
  account_id=$(echo "$caller_identity" | jq -r '.Account')
  caller_user=$(echo "$caller_identity" | jq -r '.Arn' | sed 's|.*/||')
  [[ -n "$account_id" && -n "$caller_user" ]] || die "Failed to parse caller identity"

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
  # The three legacy "deployer" policies still attach directly to the deploy
  # role (rockport-deploy-role) and, through phase 4 of spec 017, to the
  # rockport-deployer USER as a fallback. Phase 5 detaches them from the user.
  #
  # The two operator-tier policies (RockportOperatorReadonly, ...RuntimeOps)
  # back rockport-readonly-role and rockport-runtime-ops-role respectively.
  # They are referenced by terraform/iam-operator-roles.tf via ARN.
  #
  # RockportDeployerAssumeRoles is the policy that attaches to the deployer
  # USER (phase 2 onwards) and grants MFA-conditioned sts:AssumeRole on the
  # three operator roles.
  local policy_names=(
    "RockportDeployerCompute"
    "RockportDeployerIamSsm"
    "RockportDeployerMonitoringStorage"
    "RockportOperatorReadonly"
    "RockportOperatorRuntimeOps"
    "RockportDeployerAssumeRoles"
  )
  local policy_files=(
    "$policy_dir/compute.json"
    "$policy_dir/iam-ssm.json"
    "$policy_dir/monitoring-storage.json"
    "$policy_dir/readonly.json"
    "$policy_dir/runtime-ops.json"
    "$policy_dir/assume-roles.json"
  )

  for i in "${!policy_names[@]}"; do
    upsert_iam_policy "${policy_names[$i]}" "${policy_files[$i]}" "$account_id"
  done

  # Subset of the policies that actually attach to USERS in phase 1.
  # Operator-tier policies (RockportOperator*) only attach to roles via
  # terraform; they are NOT user-attached.
  # RockportDeployerAssumeRoles attaches only to rockport-deployer (phase 2);
  # rockport-admin doesn't need the indirection — admin already has direct
  # broad permissions.
  local user_policy_names=(
    "RockportDeployerCompute"
    "RockportDeployerIamSsm"
    "RockportDeployerMonitoringStorage"
  )

  # --- Deployer user ---
  if aws iam get-user --user-name "$deployer_user" &>/dev/null; then
    echo "  IAM user ............. ok ($deployer_user)"
  else
    aws iam create-user --user-name "$deployer_user" >/dev/null \
      || die "Failed to create IAM user $deployer_user"
    echo "  IAM user ............. created ($deployer_user)"
  fi

  # Phase 5 (017) cutover: rockport-deployer holds ONLY RockportDeployerAssumeRoles.
  # The three legacy direct-attachments are removed — the deploy operator role
  # is the only path to deployer-tier permissions. The calling admin user
  # keeps the legacy policies attached so admin can still execute emergency
  # direct-deploys without the role assumption flow (and so init itself works
  # in the bootstrap chicken-and-egg).
  for i in "${!user_policy_names[@]}"; do
    attach_iam_policy "$caller_user" "${user_policy_names[$i]}" "$account_id"
    detach_iam_policy "$deployer_user" "${user_policy_names[$i]}" "$account_id" "phase-5 cutover"
  done

  # rockport-deployer's only attachment after phase 5 is the AssumeRoles
  # policy. Idempotent.
  attach_iam_policy "$deployer_user" "RockportDeployerAssumeRoles" "$account_id"

  local existing_keys
  existing_keys=$(aws iam list-access-keys --user-name "$deployer_user" --query 'length(AccessKeyMetadata)' --output text) \
    || die "Failed to list access keys for $deployer_user"

  if [[ "$existing_keys" -gt 0 ]]; then
    echo "  Access keys .......... ok (already configured)"
  else
    local key_output
    key_output=$(aws iam create-access-key --user-name "$deployer_user" --output json) \
      || die "Failed to create access key for $deployer_user"
    local access_key secret_key
    access_key=$(echo "$key_output" | jq -r '.AccessKey.AccessKeyId')
    secret_key=$(echo "$key_output" | jq -r '.AccessKey.SecretAccessKey')
    [[ -n "$access_key" && -n "$secret_key" ]] || die "Failed to parse access key output"

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
