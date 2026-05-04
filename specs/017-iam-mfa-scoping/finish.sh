#!/usr/bin/env bash
# 017 finish — drive the rest of the rollout: smoke tests → push → PR → merge → tag.
#
# This script is interactive at each step (y/n/q) so you can pause if anything
# looks wrong. It never auto-merges or auto-tags without confirmation.
#
# Prerequisites (already done by this point):
#   - operator roles created on AWS (phase 4 of rollout.sh)
#   - MFA enrolled, MFA_SERIAL_NUMBER in terraform/.env (phase 6)
#   - [rockport] profile configured (recover-rockport-profile.sh)
#   - working tree clean, on 017-iam-mfa-scoping branch
#
# Usage:
#   ./specs/017-iam-mfa-scoping/finish.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || { echo "ERROR: cannot cd to $REPO" >&2; exit 1; }

BRANCH="017-iam-mfa-scoping"
NEW_TAG="v1.3.0"

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m' "$*"; }
phase()    { echo; echo "============================================================"; echo "  $(c_bold "$1")"; echo "============================================================"; echo; }
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

# --- pre-flight ----------------------------------------------------------
phase "PRE-FLIGHT — branch / clean tree / tools"

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "$BRANCH" ]]; then
  bad "expected branch $BRANCH, on $current_branch"
  ask "switch to $BRANCH?" || exit 1
  git checkout "$BRANCH" || { bad "checkout failed"; exit 1; }
fi
ok "on branch $BRANCH"

if [[ -n "$(git status --porcelain)" ]]; then
  bad "working tree is not clean"
  git status --short | sed 's/^/    /'
  ask "continue anyway?" n || exit 1
else
  ok "working tree clean"
fi

for cmd in aws gh git jq; do
  command -v "$cmd" >/dev/null || { bad "missing $cmd"; exit 1; }
done
ok "tools: aws, gh, git, jq"

unset AWS_PROFILE
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || { bad "AWS creds not working"; exit 1; }
ok "AWS account: $ACCOUNT"

# --- step 1: re-run smoke tests (phase 7 only, with the fixed harness) ---
phase "STEP 1 — phase 7 smoke tests (SC-005 + SC-006), fixed harness"

cat <<'EOM'
  Two acceptance tests. You'll be prompted for TOTP twice (once per role).

    SC-006 — readonly cannot ssm:SendCommand
    SC-005 — deploy cannot iam:CreatePolicyVersion against its own backing policies

  Both must PASS before we continue. The harness now passes
  --profile rockport-<role> explicitly and verifies sts:get-caller-identity
  before grading the result, so a profile mismatch hard-fails instead of
  silently running as admin.

EOM

if ask "run smoke tests now?"; then
  SMOKE_OK=1

  # SC-006: readonly must NOT be allowed to SendCommand.
  if ./scripts/rockport.sh auth --role readonly; then
    caller=$(aws --profile rockport-readonly sts get-caller-identity \
               --query Arn --output text 2>/dev/null || true)
    if [[ "$caller" == *":assumed-role/rockport-readonly-role/"* ]]; then
      ok "harness running as readonly: $caller"
      out=$(aws --profile rockport-readonly ssm send-command \
              --document-name AWS-RunShellScript \
              --instance-ids i-0000000000000fake \
              --parameters '{"commands":["whoami"]}' 2>&1 || true)
      if echo "$out" | grep -qE "AccessDenied|not authorized"; then
        ok "SC-006 PASS: readonly is denied ssm:SendCommand"
      elif echo "$out" | grep -qE "InvalidInstanceId|InstanceIdNotFound"; then
        bad "SC-006 REGRESSION: readonly was allowed past IAM into instance lookup"
        bad "   response: $out"
        SMOKE_OK=0
      else
        bad "SC-006 unexpected: $out"
        SMOKE_OK=0
      fi
    else
      bad "harness sanity check: caller=$caller (expected rockport-readonly-role)"
      SMOKE_OK=0
    fi
  else
    bad "could not assume readonly role"
    SMOKE_OK=0
  fi

  # SC-005: deploy must NOT be allowed to mutate IAM policies.
  if ./scripts/rockport.sh auth --role deploy; then
    caller=$(aws --profile rockport-deploy sts get-caller-identity \
               --query Arn --output text 2>/dev/null || true)
    if [[ "$caller" == *":assumed-role/rockport-deploy-role/"* ]]; then
      ok "harness running as deploy: $caller"
      out=$(aws --profile rockport-deploy iam create-policy-version \
              --policy-arn "arn:aws:iam::${ACCOUNT}:policy/RockportDeployerCompute" \
              --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"Pwnz","Effect":"Allow","Action":"*","Resource":"*"}]}' \
              --set-as-default 2>&1 || true)
      if echo "$out" | grep -qE "AccessDenied|not authorized"; then
        ok "SC-005 PASS: deploy is denied iam:CreatePolicyVersion (Finding B closed)"
      else
        bad "SC-005 REGRESSION: deploy created a new policy version"
        bad "   response: $out"
        bad "   *** rotate RockportDeployerCompute now and STOP ***"
        SMOKE_OK=0
      fi
    else
      bad "harness sanity check: caller=$caller (expected rockport-deploy-role)"
      SMOKE_OK=0
    fi
  else
    bad "could not assume deploy role"
    SMOKE_OK=0
  fi

  unset AWS_PROFILE

  if (( SMOKE_OK == 0 )); then
    bad "smoke tests failed — investigate before pushing"
    exit 1
  fi
  ok "both smoke tests passed"
else
  warn "skipped — but DO NOT cut a release without them"
  ask "still continue to push?" n || exit 1
fi

# --- step 2: push branch -------------------------------------------------
phase "STEP 2 — push $BRANCH to origin"

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
if [[ -z "$UPSTREAM" ]]; then
  warn "no upstream set — will push with -u"
  if ask "push to origin/$BRANCH?"; then
    git push -u origin "$BRANCH" || { bad "push failed"; exit 1; }
    ok "pushed"
  else
    warn "skipped — PR creation will fail without a remote branch"
    exit 1
  fi
else
  ok "upstream: $UPSTREAM"
  AHEAD=$(git rev-list --count '@{u}'..HEAD 2>/dev/null || echo "?")
  if [[ "$AHEAD" -gt 0 ]]; then
    if ask "$AHEAD commit(s) ahead of upstream — push?"; then
      git push || { bad "push failed"; exit 1; }
      ok "pushed"
    fi
  else
    ok "already up-to-date with upstream"
  fi
fi

# --- step 3: create or find PR ------------------------------------------
phase "STEP 3 — create or reuse PR"

PR_NUM=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)
if [[ -n "$PR_NUM" && "$PR_NUM" != "null" ]]; then
  ok "PR already exists: #$PR_NUM"
else
  if ask "create PR now?"; then
    gh pr create \
      --title "feat: IAM MFA + per-skill scoping (spec 017)" \
      --body "$(cat <<'EOF'
## Summary

- Three MFA-gated operator roles (readonly / runtime-ops / deploy) replacing the long-lived rockport-deployer access pattern.
- 1-hour STS sessions; trust policy requires `aws:MultiFactorAuthPresent=true` and `aws:MultiFactorAuthAge<3600`.
- `SUBCOMMAND_ROLE` map in `scripts/rockport.sh` routes every subcommand to the least-privilege role.
- Avoids both Appserver 003 outstanding findings:
  - Finding A: readonly has zero `ssm:SendCommand` (graceful HTTP fallback in `cmd_status`; `--instance` flag escalates to runtime-ops).
  - Finding B: deploy boundary explicitly denies IAM-policy / IAM-user / access-key mutation.
- Cross-project deny is `Resource`-scoped to `arn:aws:iam::*:role/rockport*` so Appserver IAM operations are unaffected.

## Test plan

- [x] `tests/auth-flow-test.sh` — 53 sandboxed cases covering assume_role, session caching, role resolution
- [x] terraform fmt + validate clean
- [x] shellcheck clean on `scripts/`, `tests/`
- [x] live deploy on 2026-05-04 — three operator roles created, MFA enrolled, [rockport] profile configured
- [x] SC-005 — deploy role denied `iam:CreatePolicyVersion` (verified live via fixed phase-7 harness + IAM simulator)
- [x] SC-006 — readonly role denied `ssm:SendCommand AWS-RunShellScript`
- [x] pentest run under new flow: 12 passed, 0 failed, 1 skipped (destructive injection)

## Notes for reviewer

- See `specs/017-iam-mfa-scoping/HANDOFF.md` for the full incident log including the live-apply lessons (DenyAttachToInstanceRole carve-out, cross-project AppserverDeployerIamSsm detach, smoke-harness profile bug).
- `recover-rockport-profile.sh` and `resume.sh` are operator-only one-shot recovery scripts kept in the spec dir for repeatability.
EOF
)"
    PR_NUM=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number')
    ok "PR created: #$PR_NUM"
  else
    warn "skipped — can't merge without a PR"
    exit 1
  fi
fi

PR_URL=$(gh pr view "$PR_NUM" --json url --jq .url)
ok "PR URL: $PR_URL"

# --- step 4: wait for CI ------------------------------------------------
phase "STEP 4 — wait for CI"

if ask "watch CI now? (Ctrl-C is safe; you can re-run finish.sh later)"; then
  if gh pr checks "$PR_NUM" --watch --fail-fast; then
    ok "CI green"
  else
    bad "CI failed — investigate before merging"
    gh pr checks "$PR_NUM" | sed 's/^/    /' || true
    ask "continue to merge anyway?" n || exit 1
  fi
else
  warn "skipped — verify CI is green before continuing"
fi

# --- step 5: merge -------------------------------------------------------
phase "STEP 5 — merge PR #$PR_NUM (squash, matches recent project style)"

if ask "squash-merge PR #$PR_NUM into main?" n; then
  gh pr merge "$PR_NUM" --squash --delete-branch \
    || { bad "merge failed"; exit 1; }
  ok "merged + remote branch deleted"
else
  warn "skipped — re-run finish.sh once you're ready"
  exit 0
fi

# --- step 6: refresh local main -----------------------------------------
phase "STEP 6 — switch to main + pull"

git checkout main || { bad "checkout main failed"; exit 1; }
git pull --ff-only origin main || { bad "pull failed"; exit 1; }
ok "on main, up-to-date"

# --- step 7: tag release ------------------------------------------------
phase "STEP 7 — tag $NEW_TAG"

if git rev-parse "$NEW_TAG" >/dev/null 2>&1; then
  warn "$NEW_TAG already exists locally"
  ask "skip tagging?" || exit 1
else
  if ask "annotate + push tag $NEW_TAG?"; then
    git tag -a "$NEW_TAG" -m "$(cat <<EOF
$NEW_TAG — IAM MFA + per-skill scoping (spec 017)

Three MFA-gated operator roles replacing the long-lived deployer pattern:
- rockport-readonly-role (no ssm:SendCommand — Finding A closed)
- rockport-runtime-ops-role
- rockport-deploy-role (boundary denies IAM-policy/user/access-key mutation — Finding B closed)

Cross-project deny scoping: rockport-* roles only, so Appserver IAM ops are unaffected.
1-hour STS sessions, MFA + age<3600 conditions on the trust policy.
EOF
)" || { bad "tag failed"; exit 1; }
    git push origin "$NEW_TAG" || { bad "tag push failed"; exit 1; }
    ok "tagged + pushed $NEW_TAG"
  else
    warn "skipped"
  fi
fi

# --- done ---------------------------------------------------------------
phase "DONE"

cat <<EOM
  Released: $(c_green "$NEW_TAG")
  PR:       $PR_URL

  Optional follow-ups (file as separate issues):
    - Appserver: scope its iam-ssm.json deny to appserver-* roles (mirror of 017/D8).
      Once shipped, AppserverDeployerIamSsm can re-attach to rockport-admin.
    - Rockport: ensure_deployer_access() in scripts/rockport.sh:736-757 should
      detect "deployer has keys but [rockport] profile missing" and rotate, not
      silently skip (root cause of today's recovery detour).
    - In a week: delete the rockport-deployer access key that was deactivated
      by recover-rockport-profile.sh (find it via:
        aws iam list-access-keys --user-name rockport-deployer
      then aws iam delete-access-key --access-key-id <id>).

  rockport-admin still carries the legacy 3 deployer policies attached. That's
  intentional — emergency direct-deploy path. If you want to harden further,
  detach them and rely solely on rockport.sh deploy via assume-role.
EOM
