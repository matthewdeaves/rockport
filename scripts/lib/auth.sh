# shellcheck shell=bash
# scripts/lib/auth.sh — operator-role auth (017) and admin MFA (018) helpers,
# plus the user-facing `auth` subcommand. Sourced by rockport.sh.
# Relies on die(), get_region(), load_env() from the parent shell.


# --- 017: per-subcommand role assumption (MFA-gated STS) ---
#
# Map top-level subcommands to operator roles. Special values:
#   admin — bypass the auth flow and use the default credential chain
#           (used by `init` which bootstraps IAM before roles exist)
#   meta  — auth subcommand handles its own session lifecycle
#
# `_resolve_role` consults flags for nuanced cases (e.g. status --instance
# escalates to runtime-ops).
declare -A SUBCOMMAND_ROLE=(
  [init]=admin
  [auth]=meta
  [status]=readonly
  [models]=readonly
  [spend]=readonly
  [monitor]=readonly
  [key]=readonly
  [setup-claude]=readonly
  [logs]=runtime-ops
  [config]=runtime-ops
  [upgrade]=runtime-ops
  [start]=runtime-ops
  [stop]=runtime-ops
  [deploy]=deploy
  [destroy]=deploy
)

_resolve_role() {
  local subcmd="$1"; shift
  local role="${SUBCOMMAND_ROLE[$subcmd]:-}"
  [[ -z "$role" ]] && { echo "readonly"; return 0; }
  # status --instance escalates to runtime-ops (needs ssm:SendCommand)
  if [[ "$subcmd" == "status" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "--instance" ]] && { echo "runtime-ops"; return 0; }
    done
  fi
  echo "$role"
}

# Returns 0 if the AWS profile $1 has a usable session token whose expiry is
# more than 5 minutes from now. Returns 1 otherwise.
_session_valid() {
  local profile="$1"
  aws configure list-profiles 2>/dev/null | grep -q "^${profile}$" || return 1
  local expiration
  expiration=$(aws configure get aws_session_expiration --profile "$profile" 2>/dev/null) || return 1
  [[ -z "$expiration" ]] && return 1
  local exp_epoch now_epoch
  exp_epoch=$(date -d "$expiration" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  (( exp_epoch - now_epoch > 300 ))
}

# Mints a 1-hour STS session for one of the operator roles. Prompts for the
# operator's TOTP code; reads MFA_SERIAL_NUMBER from terraform/.env. Writes
# creds under the rockport-<role> profile and exports AWS_PROFILE.
assume_role() {
  local role="$1"
  local profile="rockport-${role}"
  local role_name="rockport-${role}-role"

  load_env
  if [[ -z "${MFA_SERIAL_NUMBER:-}" ]]; then
    die "MFA_SERIAL_NUMBER not set. Add it to terraform/.env after enrolling MFA on rockport-deployer (see specs/017-iam-mfa-scoping/HANDOFF.md phase 2)."
  fi

  local account_id
  account_id=$(env -u AWS_PROFILE aws sts get-caller-identity --profile rockport --query Account --output text 2>/dev/null) \
    || die "Could not get account ID via the long-lived rockport profile. Configure ~/.aws/credentials [rockport] first or run rockport.sh init."

  local role_arn="arn:aws:iam::${account_id}:role/${role_name}"
  local session_name
  session_name="${role//-/_}_$(date +%s)"

  local code=""
  while [[ ! "$code" =~ ^[0-9]{6}$ ]]; do
    read -rsp "TOTP code for ${role_name}: " code
    echo
    [[ ! "$code" =~ ^[0-9]{6}$ ]] && echo "  (need a 6-digit code; try again)" >&2
  done

  local creds
  creds=$(env -u AWS_PROFILE aws sts assume-role \
    --profile rockport \
    --role-arn "$role_arn" \
    --role-session-name "$session_name" \
    --serial-number "$MFA_SERIAL_NUMBER" \
    --token-code "$code" \
    --duration-seconds 3600 \
    --output json) || die "sts:AssumeRole failed for ${role_name}"

  local access_key secret_key session_token expiration
  access_key=$(echo "$creds"    | jq -r '.Credentials.AccessKeyId')
  secret_key=$(echo "$creds"    | jq -r '.Credentials.SecretAccessKey')
  session_token=$(echo "$creds" | jq -r '.Credentials.SessionToken')
  expiration=$(echo "$creds"    | jq -r '.Credentials.Expiration')
  [[ -n "$access_key" && "$access_key" != "null" ]] || die "Failed to parse sts:AssumeRole response"

  aws configure set aws_access_key_id "$access_key" --profile "$profile"
  aws configure set aws_secret_access_key "$secret_key" --profile "$profile"
  aws configure set aws_session_token "$session_token" --profile "$profile"
  aws configure set aws_session_expiration "$expiration" --profile "$profile"
  aws configure set region "$(get_region 2>/dev/null || echo us-east-1)" --profile "$profile"
  aws configure set output json --profile "$profile"

  export AWS_PROFILE="$profile"
  echo "  Assumed ${role_name} until ${expiration}" >&2
}

# Mints a 1-hour MFA-derived STS session for the rockport-admin user (used by
# `init` and any other admin-only path). Reads ROCKPORT_ADMIN_MFA_SERIAL from
# terraform/.env. Writes creds under the rockport-admin-mfa profile and
# exports AWS_PROFILE. Skipped if ROCKPORT_AUTH_DISABLED=1 (true bootstrap on
# a fresh account where no IAM policy enforces MFA yet).
admin_mfa_session() {
  [[ "${ROCKPORT_AUTH_DISABLED:-0}" == "1" ]] && return 0

  local profile="rockport-admin-mfa"

  load_env
  if [[ -z "${ROCKPORT_ADMIN_MFA_SERIAL:-}" ]]; then
    die "ROCKPORT_ADMIN_MFA_SERIAL not set. Enrol MFA on rockport-admin in the AWS console and add the device ARN to terraform/.env (see terraform/.env.example). Or set ROCKPORT_AUTH_DISABLED=1 only when bootstrapping a fresh account where the RockportAdmin policy isn't deployed yet."
  fi

  if _session_valid "$profile"; then
    export AWS_PROFILE="$profile"
    return 0
  fi

  local code=""
  while [[ ! "$code" =~ ^[0-9]{6}$ ]]; do
    read -rsp "TOTP code for rockport-admin: " code
    echo
    [[ ! "$code" =~ ^[0-9]{6}$ ]] && echo "  (need a 6-digit code; try again)" >&2
  done

  local creds
  creds=$(env -u AWS_PROFILE aws sts get-session-token \
    --serial-number "$ROCKPORT_ADMIN_MFA_SERIAL" \
    --token-code "$code" \
    --duration-seconds 3600 \
    --output json) || die "sts:GetSessionToken failed for rockport-admin"

  local access_key secret_key session_token expiration
  access_key=$(echo "$creds"    | jq -r '.Credentials.AccessKeyId')
  secret_key=$(echo "$creds"    | jq -r '.Credentials.SecretAccessKey')
  session_token=$(echo "$creds" | jq -r '.Credentials.SessionToken')
  expiration=$(echo "$creds"    | jq -r '.Credentials.Expiration')
  [[ -n "$access_key" && "$access_key" != "null" ]] || die "Failed to parse sts:GetSessionToken response"

  aws configure set aws_access_key_id "$access_key" --profile "$profile"
  aws configure set aws_secret_access_key "$secret_key" --profile "$profile"
  aws configure set aws_session_token "$session_token" --profile "$profile"
  aws configure set aws_session_expiration "$expiration" --profile "$profile"
  aws configure set region "$(get_region 2>/dev/null || echo eu-west-2)" --profile "$profile"
  aws configure set output json --profile "$profile"

  export AWS_PROFILE="$profile"
  echo "  Assumed rockport-admin (MFA) until ${expiration}" >&2
}

# Idempotent: ensures AWS_PROFILE points at a valid session for the requested
# operator role. Refreshes via assume_role if expired or missing.
#
# Phase 5 (017) cutover: the legacy long-lived `rockport` profile fallback
# has been removed. Every operator-role subcommand now requires an
# MFA-derived STS session.
ensure_session_valid_for_role() {
  local role="$1"
  [[ "${ROCKPORT_AUTH_DISABLED:-0}" == "1" ]] && return 0

  local profile="rockport-${role}"
  if _session_valid "$profile"; then
    export AWS_PROFILE="$profile"
    return 0
  fi

  assume_role "$role"
}

# Top-level dispatcher hook: figure out which role this subcommand needs,
# then either bypass (admin/meta) or refresh the session.
_ensure_role_for_subcommand() {
  local subcmd="$1"; shift
  [[ "${ROCKPORT_AUTH_DISABLED:-0}" == "1" ]] && return 0
  local role
  role="$(_resolve_role "$subcmd" "$@")"
  case "$role" in
    admin|meta) return 0 ;;
    readonly|runtime-ops|deploy) ensure_session_valid_for_role "$role" ;;
    *) die "Internal error: unknown role '$role' for subcommand '$subcmd'" ;;
  esac
}

cmd_auth() {
  local role=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="${2:?--role requires a name}"; shift 2 ;;
      status) shift; _cmd_auth_status "$@"; return ;;
      *) echo "Unknown auth option: $1"; echo "Usage: rockport auth [--role <readonly|runtime-ops|deploy>] | rockport auth status"; exit 1 ;;
    esac
  done
  if [[ -z "$role" ]]; then
    read -rp "Role to assume [readonly]: " role
    role="${role:-readonly}"
  fi
  case "$role" in
    readonly|runtime-ops|deploy) assume_role "$role" ;;
    *) die "Unknown role: $role (must be readonly, runtime-ops, or deploy)" ;;
  esac
}

_cmd_auth_status() {
  echo "Cached operator-role sessions:"
  local active="${AWS_PROFILE:-<unset>}"
  for role in readonly runtime-ops deploy; do
    local profile="rockport-${role}"
    local marker=" "
    [[ "$profile" == "$active" ]] && marker="*"
    if aws configure list-profiles 2>/dev/null | grep -q "^${profile}$"; then
      local expiration
      expiration=$(aws configure get aws_session_expiration --profile "$profile" 2>/dev/null) || expiration=""
      if [[ -n "$expiration" ]]; then
        local exp_epoch now_epoch remaining
        exp_epoch=$(date -d "$expiration" +%s 2>/dev/null) || exp_epoch=0
        now_epoch=$(date +%s)
        remaining=$(( exp_epoch - now_epoch ))
        if (( remaining > 0 )); then
          printf "  %s %-20s valid for %d min (until %s)\n" "$marker" "$profile" "$((remaining / 60))" "$expiration"
        else
          printf "  %s %-20s expired (%s)\n" "$marker" "$profile" "$expiration"
        fi
      else
        printf "  %s %-20s present but no expiration recorded\n" "$marker" "$profile"
      fi
    else
      printf "    %-20s not yet assumed\n" "$profile"
    fi
  done
  echo
  echo "Active AWS_PROFILE: ${active}"
}

# Phase 5 (017): the legacy "auto-pick rockport profile if present" behaviour
# is intentionally gone. AWS_PROFILE is set per-subcommand by
# _ensure_role_for_subcommand, which assumes the right operator role with MFA.
# The only escape hatch is ROCKPORT_AUTH_DISABLED=1 (used by the bootstrap
# `init` flow on a fresh account, where operator roles don't yet exist).
