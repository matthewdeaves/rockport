#!/usr/bin/env bash
# shellcheck disable=SC2016  # sandbox bodies use literal $VAR strings on purpose
# auth-flow-test.sh — assertion harness for the operator-role auth helpers
# in scripts/rockport.sh (assume_role, ensure_session_valid_for_role,
# _session_valid, _resolve_role, cmd_auth, _cmd_auth_status, SUBCOMMAND_ROLE).
#
# Strategy:
#   - Source rockport.sh in a sandboxed shell with a stub `aws` and
#     stub `terraform` on PATH ahead of the real binaries.
#   - Stubs read intent from env vars (e.g. STUB_ASSUME_ROLE_OUTPUT,
#     STUB_ACCOUNT_ID) so each test sets up its own world.
#   - Profiles are written to a temp HOME so we don't touch the
#     operator's real ~/.aws/credentials.
#
# Run:
#   bash tests/auth-flow-test.sh
#
# Exits non-zero if any case fails. Wired into CI by validate.yml.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROCKPORT_SH="$REPO_ROOT/scripts/rockport.sh"

PASS=0
FAIL=0
FAILED_CASES=()

SANDBOX_ROOT=$(mktemp -d -t rockport-auth-test.XXXXXX)
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

mk_sandbox() {
  local name="$1"
  local sb="$SANDBOX_ROOT/$name"
  mkdir -p "$sb/home/.aws" "$sb/bin" "$sb/repo/terraform" "$sb/repo/config"
  # Stub config/litellm-config.yaml so claude_models() doesn't die when sourcing
  printf 'model_list:\n  - model_name: claude-sonnet-4-6\n    litellm_params:\n      model: bedrock/anthropic.claude-sonnet-4-6\n' \
    > "$sb/repo/config/litellm-config.yaml"
  # Stub terraform.tfvars so get_region() doesn't shell out
  printf 'region = "eu-west-2"\n' > "$sb/repo/terraform/terraform.tfvars"
  echo "$sb"
}

make_stub_aws() {
  local sb="$1"
  cat >"$sb/bin/aws" <<'STUB'
#!/usr/bin/env bash
# Stub `aws` for auth-flow-test.sh. Driven by env vars:
#   STUB_ACCOUNT_ID         — for `sts get-caller-identity --query Account`
#   STUB_ASSUME_ROLE_OUTPUT — JSON returned by `sts assume-role`
#   STUB_LIST_PROFILES      — newline-separated for `configure list-profiles`
#   STUB_ASSUME_ROLE_FAIL=1 — make `sts assume-role` exit 1
#
# `aws configure set/get` actually edits ~/.aws/credentials in the sandbox
# HOME so we test real INI-file behaviour.

set -uo pipefail

REAL_AWS=""
for p in /usr/local/bin/aws /usr/bin/aws "$HOME/.local/bin/aws"; do
  [ -x "$p" ] && REAL_AWS="$p" && break
done
if [ -z "$REAL_AWS" ]; then
  while read -r p; do
    [ "$p" = "$0" ] && continue
    [ -x "$p" ] || continue
    REAL_AWS="$p"
    break
  done < <(command -v -a aws 2>/dev/null)
fi

case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    if [ -n "${STUB_ACCOUNT_ID:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          Account) echo "$STUB_ACCOUNT_ID"; exit 0 ;;
        esac
      done
      printf '{"Account":"%s","Arn":"arn:aws:iam::%s:user/test","UserId":"AIDA"}\n' \
        "$STUB_ACCOUNT_ID" "$STUB_ACCOUNT_ID"
    fi
    exit 0
    ;;
  "sts assume-role")
    if [ -n "${STUB_ASSUME_ROLE_FAIL:-}" ]; then
      echo "AccessDenied stub failure" >&2
      exit 1
    fi
    if [ -n "${STUB_ASSUME_ROLE_OUTPUT:-}" ]; then
      echo "$STUB_ASSUME_ROLE_OUTPUT"
      exit 0
    fi
    echo "stub: STUB_ASSUME_ROLE_OUTPUT not set" >&2
    exit 1
    ;;
  "configure list-profiles")
    if [ -n "${STUB_LIST_PROFILES:-}" ]; then
      printf '%s\n' "$STUB_LIST_PROFILES"
      exit 0
    fi
    [ -n "$REAL_AWS" ] && exec "$REAL_AWS" "$@"
    exit 0
    ;;
  "configure "*)
    [ -n "$REAL_AWS" ] && exec "$REAL_AWS" "$@"
    exit 1
    ;;
esac
echo "stub: unhandled aws call: $*" >&2
exit 99
STUB
  chmod +x "$sb/bin/aws"
}

make_stub_terraform() {
  local sb="$1"
  cat >"$sb/bin/terraform" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: never invoke real terraform during tests.
exit 1
STUB
  chmod +x "$sb/bin/terraform"
}

# Source rockport.sh in a subshell with the sandbox active. Pass no args so
# the dispatcher's empty-arg branch fires `usage` (no AWS calls).
run_in_sandbox() {
  local sb="$1"; shift
  local body="$*"

  HOME="$sb/home" \
  PATH="$sb/bin:$PATH" \
  bash -c '
    set -uo pipefail
    cd "'"$sb"'/repo"
    set --
    source "'"$ROCKPORT_SH"'" >/dev/null 2>&1 || true
    # Neuter ENV_FILE so load_env() cannot re-source the real terraform/.env
    # and silently undo the test sandboxing of MFA_SERIAL_NUMBER etc.
    ENV_FILE=/dev/null
    '"$body"'
  ' </dev/null
}

assert_pass() { local label="$1" rc="$2"; if [ "$rc" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED_CASES+=("[fail rc=$rc] $label"); fi; }
assert_fail() { local label="$1" rc="$2"; if [ "$rc" -ne 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED_CASES+=("[expected nonzero rc] $label"); fi; }
assert_eq()   { local label="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED_CASES+=("[$label] want='$want' got='$got'"); fi; }
assert_match(){ local label="$1" pat="$2" got="$3"; if echo "$got" | grep -qE "$pat"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED_CASES+=("[$label] pattern='$pat' missed in: $got"); fi; }

# ============================================================================
# _resolve_role — subcommand → role mapping with --instance escalation
# ============================================================================
SB=$(mk_sandbox resolve-role); make_stub_aws "$SB"; make_stub_terraform "$SB"

assert_eq "resolve_role: status default → readonly" "readonly" \
  "$(run_in_sandbox "$SB" '_resolve_role status')"
assert_eq "resolve_role: status --instance → runtime-ops" "runtime-ops" \
  "$(run_in_sandbox "$SB" '_resolve_role status --instance')"
assert_eq "resolve_role: deploy → deploy" "deploy" \
  "$(run_in_sandbox "$SB" '_resolve_role deploy')"
assert_eq "resolve_role: config → runtime-ops" "runtime-ops" \
  "$(run_in_sandbox "$SB" '_resolve_role config push')"
assert_eq "resolve_role: init → admin" "admin" \
  "$(run_in_sandbox "$SB" '_resolve_role init')"
assert_eq "resolve_role: auth → meta" "meta" \
  "$(run_in_sandbox "$SB" '_resolve_role auth')"
assert_eq "resolve_role: unknown → readonly" "readonly" \
  "$(run_in_sandbox "$SB" '_resolve_role bogosity')"

# ============================================================================
# _session_valid — only true when expiration is >5 min away
# ============================================================================
SB=$(mk_sandbox session-valid); make_stub_aws "$SB"; make_stub_terraform "$SB"

future_30m=$(date -u -d '+30 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$future_30m" --profile rockport-readonly
run_in_sandbox "$SB" '_session_valid rockport-readonly' >/dev/null
assert_pass "_session_valid: future 30m valid" $?

past=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$past" --profile rockport-readonly
run_in_sandbox "$SB" '_session_valid rockport-readonly' >/dev/null
assert_fail "_session_valid: expired session rejected" $?

soon=$(date -u -d '+2 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$soon" --profile rockport-readonly
run_in_sandbox "$SB" '_session_valid rockport-readonly' >/dev/null
assert_fail "_session_valid: <5min buffer rejected" $?

# Profile without expiration recorded.
SB=$(mk_sandbox session-valid-bare); make_stub_aws "$SB"; make_stub_terraform "$SB"
HOME="$SB/home" aws configure set region eu-west-2 --profile rockport-readonly
run_in_sandbox "$SB" '_session_valid rockport-readonly' >/dev/null
assert_fail "_session_valid: profile without expiration rejected" $?

# Non-existent profile.
SB=$(mk_sandbox session-missing); make_stub_aws "$SB"; make_stub_terraform "$SB"
run_in_sandbox "$SB" '_session_valid rockport-runtime-ops' >/dev/null
assert_fail "_session_valid: missing profile rejected" $?

# ============================================================================
# assume_role — writes the right profile shape on success
# ============================================================================
SB=$(mk_sandbox assume-role-success); make_stub_aws "$SB"; make_stub_terraform "$SB"

future=$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
ASSUME_OUTPUT=$(jq -nc --arg expiry "$future" '{
  Credentials: {
    AccessKeyId: "ASIA1234567890",
    SecretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    SessionToken: "FAKE_SESSION_TOKEN_FOR_TEST",
    Expiration: $expiry
  }
}')

# Pre-populate a `rockport` profile so assume_role's get-caller-identity
# discovery works (it queries via --profile rockport).
HOME="$SB/home" aws configure set aws_access_key_id    AKIASEED --profile rockport
HOME="$SB/home" aws configure set aws_secret_access_key SECRET   --profile rockport
HOME="$SB/home" aws configure set region                eu-west-2 --profile rockport

out=$(STUB_ACCOUNT_ID=111122223333 \
      STUB_ASSUME_ROLE_OUTPUT="$ASSUME_OUTPUT" \
      MFA_SERIAL_NUMBER=arn:aws:iam::111122223333:mfa/rockport-deployer \
      run_in_sandbox "$SB" '
        assume_role readonly <<<"123456" 2>&1
        echo "---"
        aws configure get aws_access_key_id --profile rockport-readonly
        aws configure get aws_session_expiration --profile rockport-readonly
      ')
echo "$out" | grep -q "ASIA1234567890"
assert_pass "assume_role: writes access key to profile" $?
echo "$out" | grep -q "$future"
assert_pass "assume_role: writes expiration to profile" $?

# Missing MFA_SERIAL_NUMBER must die.
STUB_ACCOUNT_ID=111122223333 \
  run_in_sandbox "$SB" 'assume_role readonly <<<"123456"' >/dev/null 2>&1
assert_fail "assume_role: rejects missing MFA serial" $?

# sts:AssumeRole returning an error must propagate.
STUB_ACCOUNT_ID=111122223333 \
  STUB_ASSUME_ROLE_FAIL=1 \
  MFA_SERIAL_NUMBER=arn:aws:iam::111122223333:mfa/rockport-deployer \
  run_in_sandbox "$SB" 'assume_role readonly <<<"123456"' >/dev/null 2>&1
assert_fail "assume_role: surfaces sts failure" $?

# ============================================================================
# ensure_session_valid_for_role — cached session reuse + bypass
# ============================================================================
SB=$(mk_sandbox cached-session); make_stub_aws "$SB"; make_stub_terraform "$SB"
future=$(date -u -d '+50 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_access_key_id     ASIACACHED --profile rockport-readonly
HOME="$SB/home" aws configure set aws_secret_access_key wJSECRET   --profile rockport-readonly
HOME="$SB/home" aws configure set aws_session_token     TOKEN      --profile rockport-readonly
HOME="$SB/home" aws configure set aws_session_expiration "$future" --profile rockport-readonly
HOME="$SB/home" aws configure set region                eu-west-2  --profile rockport-readonly

out=$(MFA_SERIAL_NUMBER=arn:aws:iam::1:mfa/test \
      run_in_sandbox "$SB" '
        ensure_session_valid_for_role readonly 2>&1
        echo "AWS_PROFILE=$AWS_PROFILE"
      ')
echo "$out" | grep -q "AWS_PROFILE=rockport-readonly"
assert_pass "ensure_session_valid_for_role: reuses cached fresh session" $?
got_key=$(HOME="$SB/home" aws configure get aws_access_key_id --profile rockport-readonly)
assert_eq "ensure_session_valid_for_role: cached profile untouched" "ASIACACHED" "$got_key"

# ROCKPORT_AUTH_DISABLED=1 short-circuits everything.
out=$(ROCKPORT_AUTH_DISABLED=1 \
      run_in_sandbox "$SB" 'ensure_session_valid_for_role readonly 2>&1; echo "rc=$?"')
echo "$out" | grep -q "rc=0"
assert_pass "ensure_session_valid_for_role: AUTH_DISABLED bypasses entirely" $?

# Phase 5 cutover: legacy 'rockport' profile fallback is REMOVED. Even with
# the legacy profile present, no MFA = die. The only bypass is
# ROCKPORT_AUTH_DISABLED=1 (covered above).
SB=$(mk_sandbox legacy-removed); make_stub_aws "$SB"; make_stub_terraform "$SB"
HOME="$SB/home" aws configure set aws_access_key_id     LEGACY    --profile rockport
HOME="$SB/home" aws configure set aws_secret_access_key SECRET    --profile rockport
HOME="$SB/home" aws configure set region                eu-west-2 --profile rockport

STUB_ACCOUNT_ID=111122223333 STUB_LIST_PROFILES="rockport" \
  run_in_sandbox "$SB" '
    unset MFA_SERIAL_NUMBER
    ensure_session_valid_for_role readonly
  ' >/dev/null 2>&1
assert_fail "ensure_session_valid_for_role: legacy fallback removed (phase 5)" $?

# ============================================================================
# _cmd_auth_status — shows a line per role with state
# ============================================================================
SB=$(mk_sandbox auth-status); make_stub_aws "$SB"; make_stub_terraform "$SB"
future=$(date -u -d '+45 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$future" --profile rockport-readonly
HOME="$SB/home" aws configure set region eu-west-2                  --profile rockport-readonly
past=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$past"    --profile rockport-runtime-ops
HOME="$SB/home" aws configure set region eu-west-2                  --profile rockport-runtime-ops

out=$(run_in_sandbox "$SB" '_cmd_auth_status 2>&1')
assert_match "auth status: readonly valid"     "rockport-readonly.*valid for"     "$out"
assert_match "auth status: runtime-ops expired" "rockport-runtime-ops.*expired"   "$out"
assert_match "auth status: deploy not assumed"  "rockport-deploy.*not yet assumed" "$out"

# ============================================================================
# SUBCOMMAND_ROLE coverage — every dispatcher subcommand has an entry
# ============================================================================
SB=$(mk_sandbox map-coverage); make_stub_aws "$SB"; make_stub_terraform "$SB"

keys=$(run_in_sandbox "$SB" 'printf "%s\n" "${!SUBCOMMAND_ROLE[@]}" | sort')

# Required: every top-level subcommand the dispatcher handles. Adding a
# subcommand without a SUBCOMMAND_ROLE entry should fail this test.
required=(
  init auth status models spend monitor key setup-claude
  logs config upgrade start stop deploy destroy
)
for key in "${required[@]}"; do
  if echo "$keys" | grep -qx "$key"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[SUBCOMMAND_ROLE missing key] $key")
  fi
done

# Verify every dispatcher subcommand also lives in SUBCOMMAND_ROLE — guards
# against drift in either direction.
dispatcher_keys=$(awk '
  /^case "\$\{1:-\}" in$/ { in_disp = 1; next }
  in_disp && /^  -h\|--help\|""\)/ { in_disp = 0 }
  in_disp && match($0, /^  ([a-z][a-z-]*)\)/, m) { print m[1] }
' "$ROCKPORT_SH" | sort -u)

for key in $dispatcher_keys; do
  if echo "$keys" | grep -qx "$key"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[SUBCOMMAND_ROLE missing dispatcher subcommand] $key")
  fi
done

# ============================================================================
# Result
# ============================================================================
echo
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
