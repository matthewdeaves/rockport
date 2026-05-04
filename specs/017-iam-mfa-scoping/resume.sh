#!/usr/bin/env bash
# 017 resume — pick up after the half-applied terraform deploy hit two denies.
#
# Two failures to fix:
#   1. AppserverDeployerIamSsm has the same over-broad deny that Rockport's
#      old iam-ssm.json had (Resource: "*" + StringNotLike Appserver-*).
#      When attached to rockport-admin it blocks attaching Rockport* policies
#      to rockport-* roles. Fix: detach from rockport-admin (mirror of what
#      Appserver 003 did with RockportDeployerIamSsm).
#   2. Rockport's own iam-ssm.json had a too-strict DenyAttachToInstanceRole
#      that blocked AmazonSSMManagedInstanceCore. The new policy version
#      added a carve-out for that one specific ARN. We need to upload the
#      new version (init does this) BEFORE the terraform retry.
#
# After both fixes, terraform apply resumes from where it failed — the
# resources that succeeded are already in state, the failed attachments
# get retried.
#
# Usage:
#   ./specs/017-iam-mfa-scoping/resume.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || { echo "ERROR: cannot cd to $REPO" >&2; exit 1; }

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }
phase()    { echo; echo "============================================================"; echo "  $(c_bold "$1")"; echo "============================================================"; echo; }
ok()       { echo "  $(c_green "✓") $*"; }
warn()     { echo "  $(c_yellow "!") $*"; }
bad()      { echo "  $(c_red "✗") $*" >&2; }
ask()      {
  local prompt="$1" default="${2:-y}" reply hint="[Y/n/q]"
  [[ "$default" == "n" ]] && hint="[y/N/q]"
  while true; do
    read -rp "  $prompt $hint " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes)      return 0 ;;
      n|no|s|skip) return 1 ;;
      q|quit|abort) echo; echo "  Aborted."; exit 130 ;;
      *) echo "    y/n/q please." ;;
    esac
  done
}

unset AWS_PROFILE
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || { bad "AWS creds not working"; exit 1; }
ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
USERNAME="${ARN##*/}"
ok "account: $ACCOUNT"
ok "caller : $ARN"
[[ "$USERNAME" == "rockport-admin" ]] || { warn "expected rockport-admin, got $USERNAME"; ask "continue?" n || exit 1; }

# ---------------------------------------------------------------------------
phase "STEP 1 — upload the patched RockportDeployerIamSsm (carve-out for SSM-managed policy)"
# ---------------------------------------------------------------------------

cat <<'EOM'
  The previous apply hit a deny from RockportDeployerIamSsm itself:
      DenyAttachToInstanceRole blocked attaching
      AmazonSSMManagedInstanceCore to rockport-instance-role.

  iam-ssm.json now carves that specific AWS-managed ARN out of the deny.
  We re-run init to upload the new policy version. (Init also re-does its
  attach/detach reconciliation, which is idempotent and harmless.)

EOM
if ask "run init?"; then
  if ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh init; then
    ok "init complete; new RockportDeployerIamSsm version is live"
  else
    bad "init failed — abort"; exit 1
  fi
else
  warn "skipped — terraform retry WILL hit the SSM-managed-policy deny again"
fi

# ---------------------------------------------------------------------------
phase "STEP 2 — detach AppserverDeployerIamSsm from rockport-admin (cross-project mirror bug)"
# ---------------------------------------------------------------------------

APPSERVER_IAMSSM_ARN="arn:aws:iam::${ACCOUNT}:policy/AppserverDeployerIamSsm"

cat <<'EOM'
  AppserverDeployerIamSsm has the SAME over-broad deny we just fixed in
  Rockport's iam-ssm.json:

      Effect: Deny  Action: iam:AttachRolePolicy  Resource: "*"
      Condition: StringNotLike { iam:PolicyARN: ["arn:aws:iam::*:policy/Appserver*", ...] }

  When attached to rockport-admin it blocks every iam:AttachRolePolicy
  against ANY role with a non-Appserver policy ARN — including attaching
  Rockport* policies to rockport-* roles.

  Mirror of what Appserver 003 had to do with RockportDeployerIamSsm
  (their HANDOFF.md describes the same lesson). We detach permanently;
  the right longer-term fix is to scope Appserver's deny to appserver-*
  roles only — file a follow-up on that side.

EOM
if aws iam list-attached-user-policies --user-name rockport-admin \
     --query "AttachedPolicies[?PolicyArn=='$APPSERVER_IAMSSM_ARN']" --output text 2>/dev/null \
     | grep -q "$APPSERVER_IAMSSM_ARN"; then
  if ask "detach AppserverDeployerIamSsm from rockport-admin?"; then
    aws iam detach-user-policy --user-name rockport-admin --policy-arn "$APPSERVER_IAMSSM_ARN" \
      && ok "detached" \
      || { bad "detach failed"; exit 1; }
  else
    warn "skipped — the terraform retry WILL fail with the same denies"
  fi
else
  ok "AppserverDeployerIamSsm not attached to rockport-admin (already detached or never was)"
fi

# ---------------------------------------------------------------------------
phase "STEP 3 — terraform apply (resumes from the partial state)"
# ---------------------------------------------------------------------------

cat <<'EOM'
  Terraform's last apply created most resources successfully — only the
  6 IAM role-policy attachments + the instance-role SSM attachment failed.
  Re-running picks up exactly those failed resources; everything else is
  already in state and shows no diff.

  Plan should show: 7 to add (the 7 attachments), 0 to change, 0 to destroy
  (or close to it; terraform may also detect a few config-driven updates).

EOM
if ask "run terraform deploy to resume?"; then
  if ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh deploy; then
    ok "terraform deploy complete"
  else
    bad "terraform deploy failed again — surface the new errors"
    exit 1
  fi
else
  warn "skipped"
fi

# ---------------------------------------------------------------------------
phase "STEP 4 — verify operator roles are wired up"
# ---------------------------------------------------------------------------

ALL_OK=1
for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
  attached=$(aws iam list-attached-role-policies --role-name "$role" \
              --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || echo "")
  case "$role" in
    rockport-readonly-role)
      if echo "$attached" | grep -qw "RockportOperatorReadonly"; then
        ok "$role: RockportOperatorReadonly attached"
      else
        bad "$role: missing RockportOperatorReadonly attachment"
        ALL_OK=0
      fi
      ;;
    rockport-runtime-ops-role)
      if echo "$attached" | grep -qw "RockportOperatorReadonly" \
         && echo "$attached" | grep -qw "RockportOperatorRuntimeOps"; then
        ok "$role: readonly + runtime-ops attached"
      else
        bad "$role: missing one or both attachments (got: $attached)"
        ALL_OK=0
      fi
      ;;
    rockport-deploy-role)
      if echo "$attached" | grep -qw "RockportDeployerCompute" \
         && echo "$attached" | grep -qw "RockportDeployerIamSsm" \
         && echo "$attached" | grep -qw "RockportDeployerMonitoringStorage"; then
        ok "$role: all three legacy deployer policies attached"
      else
        bad "$role: missing one or more legacy attachments (got: $attached)"
        ALL_OK=0
      fi
      ;;
  esac
done

(( ALL_OK == 1 )) && ok "all operator roles look right" || warn "investigate failures above before continuing the rollout"

# ---------------------------------------------------------------------------
phase "DONE — pick the rollout back up"
# ---------------------------------------------------------------------------

cat <<EOM
  Resume the main rollout from phase 6 (MFA enrolment):

      ./specs/017-iam-mfa-scoping/rollout.sh

  Hit 'n' through phases 0-5 (already done), 'y' on phase 6 to enrol MFA,
  'y' on phase 7 for the smoke tests.

  Follow-up reminder: Appserver's iam-ssm.json has the same over-broad
  deny that Rockport's used to have. Mirror the 017/D8 fix on the
  Appserver side (Resource-scope to appserver-* roles), then it'll be
  safe to re-attach AppserverDeployerIamSsm to rockport-admin if you
  want both projects' deployer denies on the shared admin.
EOM
