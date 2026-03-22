# Tasks: Explicit Bash Error Handling

**Input**: Design documents from `/specs/012-explicit-bash-errors/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: No test tasks — validation is via shellcheck and manual verification (see quickstart.md).

**Organization**: Tasks are grouped by user story. US1 (explicit error handling) and US2 (consistent die() pattern) are implemented together per-script since they're inseparable in practice. US3 (remove flags) is done as part of each script task. A final verification phase confirms all acceptance criteria.

## Phase 1: Setup

**Purpose**: Understand current patterns before making changes

- [X] T001 Read scripts/bootstrap.sh in full, noting every command that relies on implicit errexit and every pipeline that relies on pipefail
- [X] T002 Read scripts/rockport.sh in full, noting every command that relies on implicit errexit, every `|| true` workaround, and every `local var=$(cmd)` pattern
- [X] T003 [P] Read scripts/setup.sh in full, noting every command that relies on implicit errexit and every `curl | sh` pipeline
- [X] T004 [P] Read tests/smoke-test.sh in full, noting the check() function and how errors are already handled

**Checkpoint**: Full understanding of current error handling in all 4 scripts

---

## Phase 2: User Story 1 + 2 + 3 — bootstrap.sh (Priority: P1)

**Goal**: Replace `set -euo pipefail` with explicit error handling in the EC2 bootstrap script. This is the highest-risk script — failures leave infrastructure half-configured.

**Independent Test**: Run `shellcheck scripts/bootstrap.sh` with no new warnings. Grep for `set -e` — zero matches. Verify the script still bootstraps correctly on a fresh EC2 instance (via deploy).

- [X] T005 [US1] Remove `set -euo pipefail` (line 2) and add `die()` helper function after the shebang line in scripts/bootstrap.sh
- [X] T006 [US1] Add Terraform variable validation block after variable assignments (lines 10-16) in scripts/bootstrap.sh — loop over REGION, MASTER_KEY_SSM_PATH, TUNNEL_TOKEN_SSM_PATH, LITELLM_VERSION, CLOUDFLARED_VERSION, CLOUDFLARED_SHA256, ARTIFACTS_BUCKET and die if any is empty
- [X] T007 [US1] Add explicit error handling to swap setup section (lines 19-37) in scripts/bootstrap.sh — `|| die` on dd, chmod, mkswap, swapon, sysctl commands
- [X] T008 [US1] Add explicit error handling to PostgreSQL installation and setup section (lines 40-75) in scripts/bootstrap.sh — `|| die` on dnf install, postgresql-setup, sed, systemctl commands
- [X] T009 [US1] Add explicit error handling to database creation section (lines 77-129) in scripts/bootstrap.sh — fix psql|grep pipelines (check psql exit code separately), add `|| die` on psql CREATE/ALTER/GRANT, add `|| die` on aws ssm put-parameter
- [X] T010 [US1] Add explicit error handling to LiteLLM installation section (lines 153-187) in scripts/bootstrap.sh — `|| die` on pip install, mkdir, useradd, chown, prisma generate, prisma migrate deploy
- [X] T011 [US1] Add explicit error handling to artifact download and deployment section (lines 189-228) in scripts/bootstrap.sh — fix sha256sum|awk pipeline (separate check), `|| die` on tar, cp, chown
- [X] T012 [US1] Add explicit error handling to video sidecar setup section (lines 229-268) in scripts/bootstrap.sh — `|| die` on pip install, mkdir, cp, psql DDL
- [X] T013 [US1] Add explicit error handling to cloudflared installation section (lines 284-314) in scripts/bootstrap.sh — fix sha256sum verification, `|| die` on chmod, mv
- [X] T014 [US1] Add explicit error handling to cleanup and startup section (lines 334-345) in scripts/bootstrap.sh — `|| die` on systemctl daemon-reload, enable, start
- [X] T015 [US1] Run `shellcheck scripts/bootstrap.sh` and fix any new warnings introduced by the changes

**Checkpoint**: bootstrap.sh has zero `set -e`/`set -u`/`set -o pipefail`, has `die()`, and all commands have explicit error handling

---

## Phase 3: User Story 1 + 2 + 3 — rockport.sh (Priority: P1)

**Goal**: Replace `set -euo pipefail` with explicit error handling in the admin CLI. This is the largest script (1769 lines) with 20+ functions.

**Independent Test**: Run `shellcheck scripts/rockport.sh` with no new warnings. Run `./scripts/rockport.sh status` and `./scripts/rockport.sh --help` — verify identical output. Grep for `set -e` — zero matches.

- [X] T016 [US1] Remove `set -euo pipefail` (line 2) and add `die()` helper function after the shebang line in scripts/rockport.sh
- [X] T017 [US1] Add explicit error handling to helper functions: get_artifacts_bucket(), package_and_upload_artifact(), get_region(), get_state_bucket() in scripts/rockport.sh — add `|| die` after aws/terraform calls that lack checks
- [X] T018 [US1] Add explicit error handling to get_master_key(), get_instance_id(), get_tunnel_url(), get_cf_credentials() in scripts/rockport.sh — these already have some error handling, verify completeness
- [X] T019 [US1] Add explicit error handling to ssm_run() and api_call() in scripts/rockport.sh — verify aws ssm send-command and curl calls have explicit checks
- [X] T020 [US1] Add explicit error handling to upsert_iam_policy(), delete_all_policy_versions(), attach_iam_policy() in scripts/rockport.sh — `|| die` on aws iam calls
- [X] T021 [US1] Add explicit error handling to ensure_deployer_access() in scripts/rockport.sh — this has 15+ aws iam calls with minimal error handling, add `|| die` on each
- [X] T022 [US1] Add explicit error handling to cmd_init() in scripts/rockport.sh — `|| die` on openssl, mktemp, aws ssm, terraform init/apply
- [X] T023 [US1] Add explicit error handling to cmd_status() in scripts/rockport.sh — for jq pipelines, check the result variable is non-empty rather than adding `|| die` to every echo|jq
- [X] T024 [US1] Add explicit error handling to cmd_key_create(), cmd_key_list(), cmd_key_info(), cmd_key_revoke() in scripts/rockport.sh — `|| die` on jq payload construction and api_call results
- [X] T025 [US1] Add explicit error handling to cmd_models() in scripts/rockport.sh
- [X] T026 [US1] Add explicit error handling to cmd_spend() and all spend subcommands (keys, models, daily, today, infra) in scripts/rockport.sh — `|| die` on api_call, check jq results
- [X] T027 [US1] Add explicit error handling to cmd_monitor() in scripts/rockport.sh
- [X] T028 [US1] Add explicit error handling to cmd_config_push() in scripts/rockport.sh — `|| die` on mktemp, jq, aws ssm send-command
- [X] T029 [US1] Add explicit error handling to cmd_deploy(), cmd_destroy() in scripts/rockport.sh — `|| die` on terraform commands
- [X] T030 [US1] Add explicit error handling to cmd_start(), cmd_stop() in scripts/rockport.sh — `|| die` on aws ec2 describe-instances
- [X] T031 [US1] Add explicit error handling to cmd_upgrade(), cmd_logs(), cmd_setup_claude() in scripts/rockport.sh
- [X] T032 [US1] Review and clean up `|| true` instances in scripts/rockport.sh — remove those that exist solely to work around `set -e`; keep those in cleanup/traps and genuinely optional operations (grep returning empty, optional service stops)
- [X] T033 [US1] Run `shellcheck scripts/rockport.sh` and fix any new warnings introduced by the changes

**Checkpoint**: rockport.sh has zero `set -e`/`set -u`/`set -o pipefail`, has `die()`, all commands have explicit error handling, unnecessary `|| true` removed

---

## Phase 4: User Story 1 + 2 + 3 — setup.sh (Priority: P2)

**Goal**: Replace `set -euo pipefail` with explicit error handling in the dev tool installer.

**Independent Test**: Run `shellcheck scripts/setup.sh` with no new warnings. Run `./scripts/setup.sh` on a machine with tools already installed — verify same output. Grep for `set -e` — zero matches.

- [X] T034 [P] [US1] Remove `set -euo pipefail` (line 2) and add `die()` helper function after the shebang line in scripts/setup.sh
- [X] T035 [US1] Add explicit error handling to all install_* functions in scripts/setup.sh — `|| die` on brew install, curl, unzip, sudo mv, dpkg, apt-get commands
- [X] T036 [US1] Fix dangerous `curl | sudo sh` pipeline (line 111, trivy install) in scripts/setup.sh — download to temp file first, check curl exit code, then execute
- [X] T037 [US1] Fix `curl | grep` pipeline (line 170, gitleaks version detection) in scripts/setup.sh — download to temp file, check curl exit code, then grep
- [X] T038 [US1] Add explicit error handling to verification section and git hooks setup in scripts/setup.sh
- [X] T039 [US1] Run `shellcheck scripts/setup.sh` and fix any new warnings introduced by the changes

**Checkpoint**: setup.sh has zero `set -e`/`set -u`/`set -o pipefail`, has `die()`, all commands have explicit error handling

---

## Phase 5: User Story 1 + 2 + 3 — smoke-test.sh (Priority: P2)

**Goal**: Replace `set -euo pipefail` with explicit error handling in the test harness. Minimal changes — the script's check() function already handles test pass/fail.

**Independent Test**: Run `shellcheck tests/smoke-test.sh` with no new warnings. Grep for `set -e` — zero matches.

- [X] T040 [P] [US1] Remove `set -euo pipefail` (line 2) and add `die()` helper function after the shebang line in tests/smoke-test.sh
- [X] T041 [US1] Add explicit error handling to test setup section (lines 25-35) in tests/smoke-test.sh — the key creation and VALID_KEY extraction must fail loudly if they fail (already has some checking, verify completeness)
- [X] T042 [US1] Review test functions in tests/smoke-test.sh — verify check() and check_status() properly handle curl failures; add `|| die` only to setup/teardown code, not to test assertions
- [X] T043 [US1] Run `shellcheck tests/smoke-test.sh` and fix any new warnings introduced by the changes

**Checkpoint**: smoke-test.sh has zero `set -e`/`set -u`/`set -o pipefail`, has `die()`, setup/teardown code has explicit error handling

---

## Phase 6: Polish & Verification

**Purpose**: Final validation across all scripts

- [X] T044 Verify zero instances of `set -e`, `set -u`, `set -o pipefail`, `set -euo pipefail` across all .sh files in the repository by running grep
- [X] T045 Verify `die()` is defined in all 4 scripts by running grep
- [X] T046 Run `shellcheck scripts/bootstrap.sh scripts/rockport.sh scripts/setup.sh tests/smoke-test.sh` — confirm zero new warnings
- [X] T047 Run `./scripts/rockport.sh --help` and verify normal output (behavioral regression check — validates FR-006/SC-002: no behavioral change on success paths)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — read-only research
- **Phases 2-5 (Per-script)**: Depend on Phase 1 for understanding, but are independent of each other
- **Phase 6 (Verification)**: Depends on all script phases completing

### Parallel Opportunities

- **Phase 2 and Phase 4** can run in parallel (bootstrap.sh and setup.sh are independent files)
- **Phase 3 and Phase 5** can run in parallel (rockport.sh and smoke-test.sh are independent files)
- Within Phase 2: T007-T014 are sequential (sections depend on earlier sections for context)
- Within Phase 3: T017-T032 can be partially parallelized (different functions in same file, but shellcheck should run last)
- T034 and T040 are marked [P] — they can start immediately once Phase 1 is done

### Within Each Phase

- Remove `set -euo pipefail` and add `die()` FIRST (enables all subsequent changes)
- Work through script sections top-to-bottom
- Run shellcheck LAST (validates all changes together)

---

## Implementation Strategy

### MVP First (bootstrap.sh + rockport.sh)

1. Complete Phase 1: Read all scripts
2. Complete Phase 2: bootstrap.sh (highest risk)
3. Complete Phase 3: rockport.sh (largest script)
4. **STOP and VALIDATE**: shellcheck both, test rockport.sh commands
5. These two scripts are the critical path

### Incremental Delivery

1. Phase 2: bootstrap.sh → shellcheck passes
2. Phase 3: rockport.sh → shellcheck passes, CLI works
3. Phase 4: setup.sh → shellcheck passes
4. Phase 5: smoke-test.sh → shellcheck passes
5. Phase 6: Final cross-script verification
6. Each phase is independently committable

---

## Notes

- [P] tasks = different files, no dependencies
- [US1] label used throughout because US1/US2/US3 are inseparable per-script (you can't add die() without removing set -e, and you can't remove set -e without adding explicit checks)
- The research phase (Phase 1) is critical — reading each script fully before editing prevents missed error paths
- Commit after each phase completes and shellcheck passes
- rockport.sh (Phase 3) will take the most time due to 1769 lines and 20+ functions
