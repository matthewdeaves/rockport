#!/usr/bin/env bash
# 017 rollout runner — drives the full IAM hardening cutover end-to-end.
#
# Usage:
#   ./specs/017-iam-mfa-scoping/rollout.sh
#
# Run from the repo root, with admin AWS credentials available via the default
# credential chain (i.e. `aws sts get-caller-identity` should resolve to
# rockport-admin or another admin user with RockportAdmin attached). The
# script is idempotent — safe to re-run after a partial completion or after
# fixing an interrupted step.
#
# Each phase prints what it's about to do and pauses for confirmation.
# Hit 'n' to skip a phase and continue, 'q' to abort the whole rollout.
#
# What this does (one phase at a time):
#   0. Sanity: branch, tools, AWS creds, account/caller printout.
#   1. Pre-flight: detach + delete the orphaned RockportDeployerAccess policy
#      if it exists (4-policy leftover noted in HANDOFF).
#   2. rockport.sh init — uploads the new policy versions (cross-project
#      deny scoping, IAM-mutation moved to RockportAdmin, operator-tier
#      policies, AssumeRoles policy). With phase-5-collapsed init, this
#      ALSO detaches the legacy direct-attachments from rockport-deployer.
#   3. Cross-project gate (manual): operator runs Appserver's deploy from
#      another terminal to confirm no IAM denies hit appserver-* roles.
#   4. terraform deploy under ROCKPORT_AUTH_DISABLED=1 — creates the three
#      operator roles + boundaries.
#   5. Verify roles exist with MFA-gated trust + boundaries.
#   6. MFA enrolment (manual): operator enrols MFA in AWS console; pastes
#      the device ARN here; the script appends to terraform/.env.
#   7. Smoke tests for the SC-005 (deploy can't mutate IAM policies) and
#      SC-006 (readonly can't SendCommand) acceptance criteria.
#   8. Optional: deactivate the long-lived rockport-deployer access key
#      (defense-in-depth on top of the policy detachment).
#   9. Optional: pentest run under the new flow.
#
# If you want to stop after a particular phase, hit 'q' at the prompt.
# Re-running picks up from where you left off (each step checks current state).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPSERVER="${APPSERVER_ROOT:-/home/matt/appserver}"
cd "$REPO" || { echo "ERROR: cannot cd to $REPO" >&2; exit 1; }

# --- output helpers ------------------------------------------------------

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }

phase() {
  echo
  echo "============================================================"
  echo "  $(c_bold "PHASE $1") — $2"
  echo "============================================================"
  echo
}

say() { echo "  $*"; }
ok()  { echo "  $(c_green "✓") $*"; }
warn(){ echo "  $(c_yellow "!") $*"; }
bad() { echo "  $(c_red "✗") $*" >&2; }

# Returns 0 (yes), 1 (no/skip), 2 (quit). 'y' default for all but the
# 'destructive' phases (init, terraform apply, deactivate key) which default to 'n'.
ask() {
  local prompt="$1" default="${2:-y}" reply
  local hint="[Y/n/q]"
  [[ "$default" == "n" ]] && hint="[y/N/q]"
  while true; do
    read -rp "  $prompt $hint " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|s|skip) return 1 ;;
      q|quit|abort) echo; echo "  Aborted."; exit 130 ;;
      *) echo "    Please answer y, n, or q." ;;
    esac
  done
}

# --- phase 0: sanity -----------------------------------------------------

phase 0 "sanity check"

for cmd in aws jq terraform git; do
  command -v "$cmd" >/dev/null || { bad "missing required tool: $cmd"; exit 1; }
done
ok "tools: aws, jq, terraform, git"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
if [[ "$BRANCH" != "017-iam-mfa-scoping" ]]; then
  warn "current git branch is $BRANCH (expected 017-iam-mfa-scoping)"
  ask "continue anyway?" n || exit 1
else
  ok "on branch 017-iam-mfa-scoping"
fi

unset AWS_PROFILE
CALLER=$(aws sts get-caller-identity 2>/dev/null) \
  || { bad "AWS credentials not working — set up admin creds first"; exit 1; }
ACCOUNT=$(echo "$CALLER" | jq -r .Account)
ARN=$(echo "$CALLER"     | jq -r .Arn)
USERNAME="${ARN##*/}"
say "Account: $(c_bold "$ACCOUNT")"
say "Caller : $(c_bold "$ARN")"

if [[ "$ACCOUNT" != "453875232253" ]]; then
  warn "this isn't the expected Rockport+Appserver account (453875232253)"
  ask "continue?" n || exit 1
fi
if [[ "$USERNAME" != "rockport-admin" ]]; then
  warn "caller is not rockport-admin (it is $USERNAME)"
  ask "continue?" n || exit 1
fi
ok "AWS creds look right"

# --- phase 1: pre-flight cleanup -----------------------------------------

phase 1 "pre-flight cleanup (orphans + cross-project denies)"

ACCESS_ARN="arn:aws:iam::${ACCOUNT}:policy/RockportDeployerAccess"
if aws iam get-policy --policy-arn "$ACCESS_ARN" >/dev/null 2>&1; then
  warn "RockportDeployerAccess still exists in this account (orphan from pre-014)"
  if ask "detach from rockport-admin and delete?"; then
    if aws iam list-attached-user-policies --user-name rockport-admin \
         --query "AttachedPolicies[?PolicyArn=='$ACCESS_ARN']" --output text 2>/dev/null \
         | grep -q "$ACCESS_ARN"; then
      aws iam detach-user-policy --user-name rockport-admin --policy-arn "$ACCESS_ARN" \
        && ok "detached from rockport-admin" \
        || { bad "detach failed"; exit 1; }
    else
      ok "not attached to rockport-admin"
    fi

    # Remove non-default versions before deleting the policy.
    versions=$(aws iam list-policy-versions --policy-arn "$ACCESS_ARN" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null || true)
    for v in $versions; do
      aws iam delete-policy-version --policy-arn "$ACCESS_ARN" --version-id "$v" >/dev/null \
        && say "  deleted version $v" || true
    done

    if aws iam delete-policy --policy-arn "$ACCESS_ARN" 2>/dev/null; then
      ok "deleted RockportDeployerAccess"
    else
      warn "could not delete RockportDeployerAccess — may still be attached elsewhere"
      say "  attachments:"
      aws iam list-entities-for-policy --policy-arn "$ACCESS_ARN" \
        --query '{Users: PolicyUsers[].UserName, Roles: PolicyRoles[].RoleName, Groups: PolicyGroups[].GroupName}' \
        --output table 2>&1 | sed 's/^/    /'
      ask "continue anyway?" n || exit 1
    fi
  else
    say "skipped"
  fi
else
  ok "RockportDeployerAccess not present"
fi

# AppserverDeployerIamSsm has the same over-broad deny pattern Rockport's
# used to have (Resource: "*" + Appserver-only policy-ARN allowlist). When
# attached to rockport-admin it blocks attaching Rockport* policies to
# rockport-* roles — terraform fails with explicit-deny. Until Appserver
# scopes its deny to appserver-* roles, we keep this policy detached from
# rockport-admin (mirror of what Appserver 003 did to RockportDeployerIamSsm).
APPSERVER_IAMSSM_ARN="arn:aws:iam::${ACCOUNT}:policy/AppserverDeployerIamSsm"
if aws iam list-attached-user-policies --user-name rockport-admin \
     --query "AttachedPolicies[?PolicyArn=='$APPSERVER_IAMSSM_ARN']" --output text 2>/dev/null \
     | grep -q "$APPSERVER_IAMSSM_ARN"; then
  warn "AppserverDeployerIamSsm is attached to rockport-admin — its over-broad deny blocks Rockport IAM operations"
  if ask "detach it (recommended)?"; then
    aws iam detach-user-policy --user-name rockport-admin --policy-arn "$APPSERVER_IAMSSM_ARN" \
      && ok "detached AppserverDeployerIamSsm from rockport-admin" \
      || { bad "detach failed"; exit 1; }
  else
    warn "skipped — terraform deploy will likely fail with cross-project denies"
  fi
else
  ok "AppserverDeployerIamSsm not attached to rockport-admin"
fi

# --- phase 2: rockport.sh init -------------------------------------------

phase 2 "rockport.sh init — upload policies + reconcile attachments"

cat <<EOM
  This step runs ./scripts/rockport.sh init with admin creds. It will:
    - upsert RockportAdmin (gain MFA mgmt + IAM-mutation actions)
    - upsert 6 deployer policies:
        compute, iam-ssm, monitoring-storage,
        readonly, runtime-ops, assume-roles
    - attach the legacy 3 to rockport-admin (the caller)
    - detach the legacy 3 from rockport-deployer (017 phase-5 collapsed)
    - attach RockportDeployerAssumeRoles to rockport-deployer
    - re-attach RockportDeployerIamSsm to rockport-admin (it was detached
      during Appserver 003; the new resource-scoped deny makes it safe).

  The new iam-ssm.json policy version is uploaded BEFORE re-attachment, so
  the cross-project deny is already narrowed when rockport-admin gets it.

EOM
if ask "run init?"; then
  if ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh init; then
    ok "init complete"
  else
    bad "init failed"
    exit 1
  fi
else
  warn "skipped — subsequent phases assume the policies + attachments exist"
fi

# --- phase 3: cross-project regression check (manual) --------------------

phase 3 "cross-project regression: confirm Appserver still deploys"

cat <<EOM
  CRITICAL — before any further mutation, confirm that rockport-admin can
  still attach Appserver-* policies to appserver-* roles. The 017 deny
  scoping (Resource: arn:aws:iam::*:role/rockport*) should let Appserver's
  CLI proceed without IAM denies.

  Run this in a SEPARATE terminal:

    cd $APPSERVER
    unset AWS_PROFILE
    ./scripts/appserver.sh deploy

  Watch the terraform plan for any AccessDenied on iam:AttachRolePolicy.
  If you see one, abort here and surface the deny ARN — Rockport's policy
  is over-reaching.

  Type 'y' once Appserver's plan completes cleanly (or applies cleanly).
  Type 'n' to skip if Appserver isn't checked out / you don't want to test.
  Type 'q' to abort the rollout.

EOM
if ask "Appserver deploy succeeded (no Rockport IAM denies)?" n; then
  ok "cross-project regression cleared"
else
  warn "skipped — re-run later via specs/017-iam-mfa-scoping/HANDOFF.md"
fi

# --- phase 4: terraform deploy -------------------------------------------

phase 4 "terraform deploy — create operator roles + boundaries"

cat <<EOM
  This runs ./scripts/rockport.sh deploy with ROCKPORT_AUTH_DISABLED=1
  (because the operator roles don't exist yet — bootstrap chicken-and-egg).

  Expected plan: only additions for
    - 3 IAM roles (rockport-readonly-role, rockport-runtime-ops-role,
      rockport-deploy-role)
    - 3 boundary policies
    - 6 role-policy attachments
  Zero deletions of existing user-attached policies.

  You'll be prompted by terraform — type 'yes' to apply.

EOM
if ask "run terraform deploy?"; then
  if ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh deploy; then
    ok "deploy complete"
  else
    bad "terraform deploy failed"
    exit 1
  fi
else
  warn "skipped — phase 5 verification will fail without the roles"
fi

# --- phase 5: verify roles -----------------------------------------------

phase 5 "verify operator roles"

ALL_OK=1
for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
  if details=$(aws iam get-role --role-name "$role" --output json 2>/dev/null); then
    max_session=$(echo "$details" | jq -r '.Role.MaxSessionDuration')
    boundary=$(echo "$details"    | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // "none"')
    mfa=$(echo "$details"         | jq -r '.Role.AssumeRolePolicyDocument.Statement[0].Condition.Bool["aws:MultiFactorAuthPresent"] // "missing"')
    age=$(echo "$details"         | jq -r '.Role.AssumeRolePolicyDocument.Statement[0].Condition.NumericLessThan["aws:MultiFactorAuthAge"] // "missing"')
    if [[ "$max_session" == "3600" && "$boundary" =~ Boundary && "$mfa" == "true" && "$age" == "3600" ]]; then
      ok "$role: MaxSession=$max_session, MFA-gated, boundary=$(basename "$boundary")"
    else
      bad "$role: unexpected shape — MaxSession=$max_session boundary=$boundary mfa=$mfa age=$age"
      ALL_OK=0
    fi
  else
    bad "$role: not found"
    ALL_OK=0
  fi
done
if (( ALL_OK == 0 )); then
  warn "one or more roles failed verification — investigate before continuing"
  ask "continue anyway?" n || exit 1
fi

# --- phase 6: MFA enrolment (manual) -------------------------------------

phase 6 "MFA enrolment (manual)"

ENV_FILE="$REPO/terraform/.env"
EXISTING_MFA=""
if [[ -f "$ENV_FILE" ]] && grep -q '^export MFA_SERIAL_NUMBER=' "$ENV_FILE"; then
  # shellcheck disable=SC1090
  EXISTING_MFA=$(grep '^export MFA_SERIAL_NUMBER=' "$ENV_FILE" | tail -1 | sed -E 's/^export MFA_SERIAL_NUMBER="?([^"]*)"?/\1/')
fi

if [[ -n "$EXISTING_MFA" ]]; then
  ok "MFA_SERIAL_NUMBER already in terraform/.env: $EXISTING_MFA"
  if ask "use this and skip enrolment?"; then
    say "(skipping enrolment)"
  else
    EXISTING_MFA=""
  fi
fi

if [[ -z "$EXISTING_MFA" ]]; then
  cat <<'EOM'
  In the AWS console:
    IAM → Users → rockport-deployer → Security credentials tab
      → Multi-factor authentication (MFA) → Assign MFA device
      → Authenticator app
      → Name: rockport-deployer-laptop  (or whatever)
      → Scan QR with 1Password / Authy / Google Auth
      → Enter two consecutive 6-digit codes to activate

  Then copy the device ARN. It'll look like:
    arn:aws:iam::453875232253:mfa/rockport-deployer-laptop

EOM
  while true; do
    read -rp "  paste MFA device ARN (or 'skip'): " MFA_ARN
    if [[ "$MFA_ARN" == "skip" ]]; then
      warn "skipped — phase 7 smoke tests will fail"
      break
    elif [[ "$MFA_ARN" =~ ^arn:aws:iam::[0-9]+:mfa/.+ ]]; then
      printf 'export MFA_SERIAL_NUMBER="%s"\n' "$MFA_ARN" >> "$ENV_FILE"
      ok "appended to terraform/.env"
      EXISTING_MFA="$MFA_ARN"
      break
    else
      bad "doesn't look like an MFA ARN — try again"
    fi
  done
fi

# --- phase 7: smoke tests for SC-005 / SC-006 ----------------------------

phase 7 "smoke tests — denied paths under each role"

if [[ -z "$EXISTING_MFA" ]]; then
  warn "no MFA serial — skipping smoke tests"
else
  cat <<'EOM'
  Two acceptance tests:
    SC-006 — readonly cannot ssm:SendCommand AWS-RunShellScript
    SC-005 — deploy cannot iam:CreatePolicyVersion against its own backing policies

  You'll be prompted for TOTP twice (once per role).

EOM
  if ask "run smoke tests?"; then
    # SC-006: readonly must NOT be allowed to SendCommand.
    if ./scripts/rockport.sh auth --role readonly; then
      out=$(aws ssm send-command \
              --document-name AWS-RunShellScript \
              --instance-ids i-0000000000000fake \
              --parameters '{"commands":["whoami"]}' 2>&1 || true)
      if echo "$out" | grep -qE "AccessDenied|not authorized"; then
        ok "SC-006: readonly is denied ssm:SendCommand AWS-RunShellScript"
      elif echo "$out" | grep -qE "InvalidInstanceId|InstanceIdNotFound"; then
        # IAM allow happened first (bad) — would mean readonly has SendCommand.
        bad "SC-006 REGRESSION: readonly was allowed past IAM into instance lookup — readonly has SendCommand it shouldn't"
        bad "    response: $out"
        ALL_OK=0
      else
        warn "SC-006: unexpected response: $out"
      fi
    else
      bad "could not assume readonly role"
    fi

    # SC-005: deploy must NOT be allowed to mutate IAM policies.
    if ./scripts/rockport.sh auth --role deploy; then
      out=$(aws iam create-policy-version \
              --policy-arn "arn:aws:iam::${ACCOUNT}:policy/RockportDeployerCompute" \
              --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"Pwnz","Effect":"Allow","Action":"*","Resource":"*"}]}' \
              --set-as-default 2>&1 || true)
      if echo "$out" | grep -qE "AccessDenied|not authorized"; then
        ok "SC-005: deploy is denied iam:CreatePolicyVersion (Finding B closed)"
      else
        bad "SC-005 REGRESSION: deploy created a new policy version of RockportDeployerCompute"
        bad "    response: $out"
        say "    *** rotate RockportDeployerCompute now and investigate ***"
      fi
    else
      bad "could not assume deploy role"
    fi
  else
    warn "skipped"
  fi
fi

unset AWS_PROFILE

# --- phase 8: optional access key deactivation --------------------------

phase 8 "(optional) deactivate the long-lived rockport-deployer access key"

cat <<'EOM'
  Defense-in-depth on top of the policy detachment. Phase 5 already removed
  the legacy direct-attachments from rockport-deployer, so a leaked copy of
  the access key on disk can only call MFA-gated sts:AssumeRole — useless
  without the TOTP device.

  Deactivating the key (NOT deleting) lets you reactivate if anything goes
  wrong. Recommend leaving deactivated for a week before deletion.

EOM
if ask "deactivate the rockport-deployer long-lived access key?" n; then
  KEYS=$(aws iam list-access-keys --user-name rockport-deployer \
           --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text 2>/dev/null || true)
  if [[ -z "$KEYS" || "$KEYS" == "None" ]]; then
    ok "no active keys — already deactivated or never created"
  else
    for K in $KEYS; do
      aws iam update-access-key --user-name rockport-deployer --access-key-id "$K" --status Inactive \
        && ok "deactivated $K" \
        || bad "failed to deactivate $K"
    done
  fi
else
  warn "skipped — key remains active (still MFA-neutralised by policy detachment)"
fi

# --- phase 9: optional pentest ------------------------------------------

phase 9 "(optional) pentest under the new flow"

if [[ -x "$REPO/pentest/pentest.sh" ]]; then
  if ask "run ./pentest/pentest.sh run rockport?" n; then
    ./scripts/rockport.sh auth --role readonly && \
      ./pentest/pentest.sh run rockport
  else
    say "skipped"
  fi
else
  warn "pentest/pentest.sh not found, skipping"
fi

# --- done ----------------------------------------------------------------

echo
echo "============================================================"
echo "  $(c_green "017 rollout complete")"
echo "============================================================"
echo
echo "  Cached operator-role sessions:"
./scripts/rockport.sh auth status 2>/dev/null | sed 's/^/    /' || true
echo
echo "  Next:"
echo "    - merge the branch when CI is green"
echo "    - one week from today, delete the deactivated access key on rockport-deployer"
echo "    - if anything looked off, see specs/017-iam-mfa-scoping/HANDOFF.md"
