#!/usr/bin/env bash
# 017 recovery — phase 7 smoke tests can't find the [rockport] profile.
#
# Why it broke:
#   The rollout ran end-to-end with ROCKPORT_AUTH_DISABLED=1 (default chain
#   as rockport-admin), which is the right bootstrap path. But the legacy
#   `rockport` profile (rockport-deployer's long-lived access key) was never
#   written, because init only writes the profile when it has to *create* a
#   key. rockport-deployer already had an active key from a much earlier
#   bootstrap (the secret is lost), so init silently said "ok already
#   configured" and moved on.
#
#   Phase 7 (./scripts/rockport.sh auth --role readonly) now hits assume_role,
#   which hardcodes --profile rockport for the AssumeRole call (because the
#   trust policy locks AssumeRole to rockport-deployer only — admin can't).
#   No profile → instant fail.
#
# What this does:
#   1. Lists rockport-deployer access keys.
#   2. Deactivates the existing one (the secret is gone, no point keeping it
#      active — and we'd hit the 2-key max if we tried to add a third later).
#   3. Mints a fresh key for rockport-deployer.
#   4. Writes it to ~/.aws/credentials [rockport].
#   5. Verifies with sts:get-caller-identity.
#
# After this, re-run the rollout from phase 7:
#   ./specs/017-iam-mfa-scoping/rollout.sh
#   (n through 0-6, y on 7)
#
# Usage:
#   ./specs/017-iam-mfa-scoping/recover-rockport-profile.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || { echo "ERROR: cannot cd to $REPO" >&2; exit 1; }

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }
ok()   { echo "  $(c_green "✓") $*"; }
warn() { echo "  $(c_yellow "!") $*"; }
bad()  { echo "  $(c_red "✗") $*" >&2; }

ask() {
  local prompt="$1" default="${2:-y}" reply hint="[Y/n/q]"
  [[ "$default" == "n" ]] && hint="[y/N/q]"
  while true; do
    read -rp "  $prompt $hint " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|s|skip) return 1 ;;
      q|quit|abort) echo; echo "  Aborted."; exit 130 ;;
      *) echo "    y/n/q please." ;;
    esac
  done
}

unset AWS_PROFILE

# --- sanity: must be admin -----------------------------------------------
ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) \
  || { bad "AWS creds not working"; exit 1; }
USERNAME="${ARN##*/}"
ok "caller: $ARN"
if [[ "$USERNAME" != "rockport-admin" ]]; then
  warn "expected rockport-admin, got $USERNAME"
  ask "continue?" n || exit 1
fi

# --- region for the profile ----------------------------------------------
REGION=""
if [[ -f terraform/terraform.tfvars ]]; then
  REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null \
           | sed 's/.*= *"\(.*\)"/\1/' | head -n1)
fi
REGION="${REGION:-eu-west-2}"
ok "region: $REGION"

# --- step 1: deactivate any existing keys --------------------------------
echo
echo "============================================================"
echo "  $(c_bold "STEP 1") — deactivate stale access keys on rockport-deployer"
echo "============================================================"
echo

# shellcheck disable=SC2016 # JMESPath uses backticks for string literals; must be single-quoted
ACTIVE_KEYS=$(aws iam list-access-keys --user-name rockport-deployer \
                --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
                --output text 2>/dev/null || true)
if [[ -z "$ACTIVE_KEYS" || "$ACTIVE_KEYS" == "None" ]]; then
  ok "no active keys — nothing to deactivate"
else
  echo "  Active keys (you don't have the secrets on disk):"
  for k in $ACTIVE_KEYS; do echo "    - $k"; done
  echo
  if ask "deactivate them?"; then
    for k in $ACTIVE_KEYS; do
      if aws iam update-access-key --user-name rockport-deployer \
            --access-key-id "$k" --status Inactive; then
        ok "deactivated $k"
      else
        bad "failed to deactivate $k"
        exit 1
      fi
    done
  else
    warn "skipped — if rockport-deployer hits the 2-key cap, step 2 will fail"
  fi
fi

# --- step 2: create fresh key + write rockport profile -------------------
echo
echo "============================================================"
echo "  $(c_bold "STEP 2") — mint a fresh access key + configure [rockport] profile"
echo "============================================================"
echo

if ask "create new access key for rockport-deployer?"; then
  KEY_JSON=$(aws iam create-access-key --user-name rockport-deployer --output json) \
    || { bad "create-access-key failed (2-key cap?)"; exit 1; }

  ACCESS=$(echo "$KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
  SECRET=$(echo "$KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
  [[ -n "$ACCESS" && "$ACCESS" != "null" ]] || { bad "couldn't parse new key"; exit 1; }
  [[ -n "$SECRET" && "$SECRET" != "null" ]] || { bad "couldn't parse new secret"; exit 1; }

  aws configure set aws_access_key_id     "$ACCESS" --profile rockport
  aws configure set aws_secret_access_key "$SECRET" --profile rockport
  aws configure set region                "$REGION" --profile rockport
  aws configure set output                json      --profile rockport

  ok "created $ACCESS"
  ok "wrote ~/.aws/credentials [rockport]"
else
  warn "skipped — phase 7 of the rollout will keep failing"
  exit 1
fi

# --- step 3: verify -------------------------------------------------------
echo
echo "============================================================"
echo "  $(c_bold "STEP 3") — verify [rockport] profile resolves to rockport-deployer"
echo "============================================================"
echo

# IAM eventual consistency: a brand-new access key may take a few seconds
# before sts will accept it.
who=""
for _ in 1 2 3 4 5 6; do
  who=$(aws sts get-caller-identity --profile rockport --query Arn --output text 2>/dev/null || true)
  if [[ -n "$who" ]]; then break; fi
  sleep 2
done

if [[ -n "$who" ]]; then
  if [[ "$who" == *":user/rockport-deployer" ]]; then
    ok "[rockport] profile → $who"
  else
    bad "[rockport] profile resolves to $who (expected rockport-deployer)"
    exit 1
  fi
else
  bad "couldn't validate [rockport] profile after 6 attempts (12s) — IAM may still be propagating; retry in a minute"
  exit 1
fi

# --- done ----------------------------------------------------------------
echo
echo "============================================================"
echo "  $(c_green "Recovered") — re-run the rollout from phase 7"
echo "============================================================"
echo
cat <<'EOM'
  ./specs/017-iam-mfa-scoping/rollout.sh

  hit 'n' through phases 0-6 (already done)
  hit 'y' on phase 7 (smoke tests — will prompt for TOTP twice)
  hit 'y' or 'n' on phase 8 (deactivate the long-lived key) per taste —
  note: deactivating it locks you out of re-auth without console intervention,
  so leave it active if you plan to use rockport.sh auth daily.

  Follow-up note for the next time we touch init:
    ensure_deployer_access() should detect "rockport-deployer has keys but
    [rockport] profile is missing" and offer to rotate, not silently skip.
EOM
