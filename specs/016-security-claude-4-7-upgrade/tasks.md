---

description: "Task list for feature 016-security-claude-4-7-upgrade"
---

# Tasks: Security Upgrade and Claude 4.7 Support

**Input**: Design documents from `/specs/016-security-claude-4-7-upgrade/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/video-health-endpoint.md](./contracts/video-health-endpoint.md), [quickstart.md](./quickstart.md)

**Tests**: No new automated tests are added. The feature relies on the existing `tests/smoke-test.sh` (post-deploy) and `pentest/pentest.sh run rockport` (security suite). These run against the deployed instance — see Phase 11.

**Organization**: Tasks are grouped by user story per the speckit convention. Each task is atomic, imperative, carries explicit file paths, and has an obvious "done" signal (an expected grep/diff result or command exit code).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Parallelizable with adjacent [P] tasks (different files, no ordering dependency).
- **[Story]**: Which user story this task serves (US1–US9). Setup / Foundational / Polish phases have no story label.
- File paths are absolute from the repo root.

## User Story ↔ Success Criteria Map

| Story | Title | Success Criterion |
|---|---|---|
| US1 | Claude Code routing for Opus 4.7 | SC-001 |
| US2 | Proxy free of known-exploitable CVEs | SC-002 |
| US3 | Portable infrastructure (WAF var.domain) | SC-003 |
| US4 | Claude-only keys auto-cover all Claude models | SC-004 |
| US5 | Health endpoint requires auth | SC-005 |
| US6 | Per-key concurrency globally enforced | SC-006 |
| US7 | Cache pricing on every Claude alias | SC-007 |
| US8 | Dependency patch levels current | (part of SC-008) |
| US9 | Release documentation accurate | SC-010 |
| Polish | CI + deploy + smoke + pentest | SC-008, SC-009 |

---

## Phase 1: Setup

**Purpose**: Confirm the working branch, fetch verified upstream artifact (cloudflared SHA was already latest; nothing to download).

- [X] T001 Verify git working directory is clean on branch `016-security-claude-4-7-upgrade`. Done signal: `git status` reports no uncommitted changes.

---

## Phase 2: Foundational

**Purpose**: None. This feature has no cross-cutting prerequisites — every user story touches disjoint files and can proceed independently after Phase 1.

**Checkpoint**: Phase 2 skipped by design. User-story phases may begin.

---

## Phase 3: User Story 2 — Proxy free of known-exploitable CVEs (Priority: P1) 🎯 MVP-A

**Goal**: Patch the six CVEs in the pinned LiteLLM version so the re-deployed proxy is not exploitable on its authenticated request path.

**Independent Test**: After deploy, `./scripts/rockport.sh status` reports LiteLLM `1.83.7`; CI `security-scan` job reports zero HIGH/CRITICAL advisories for the pinned version.

**Note**: This user story is executed first because its absence blocks the re-deploy's safety case.

### Implementation for User Story 2

- [X] T002 [US2] Change `litellm_version` default in `terraform/variables.tf` from `"1.82.6"` to `"1.83.7"` (line 75). Done signal: `grep -c '"1.83.7"' terraform/variables.tf` returns at least 1, and `grep -c '"1.82.6"' terraform/variables.tf` returns 0.

**Checkpoint**: User Story 2 complete.

---

## Phase 4: User Story 1 — Claude Code routing for Opus 4.7 (Priority: P1) 🎯 MVP-B

**Goal**: Route the current Claude Code runtime identifier (and the canonical Opus 4.7 name) to the Bedrock Opus 4.7 model with prompt caching enabled.

**Independent Test**: A chat completion with `model=claude-opus-4-7[1m]` returns 200 content; a repeated identical system prompt on the second call reports `cache_read_input_tokens > 0`.

### Implementation for User Story 1

- [X] T003 [US1] Add two Opus 4.7 model entries to `config/litellm-config.yaml` under the Anthropic section (right after the existing `claude-haiku-4-5-20251001` entry, before the "Claude Code aliases" comment). First entry `model_name: claude-opus-4-7`, second `model_name: "claude-opus-4-7[1m]"` (quote the name because of the square brackets). Both route to `bedrock/eu.anthropic.claude-opus-4-7`, `aws_region_name: eu-west-2`, with `cache_control_injection_points: [{location: message, role: system}]`. Done signal: `grep -c 'model_name: claude-opus-4-7' config/litellm-config.yaml` returns 2 (matches both the unquoted and quoted form) AND `grep -c 'bedrock/eu.anthropic.claude-opus-4-7' config/litellm-config.yaml` returns at least 2.

**Checkpoint**: User Story 1 complete (verified post-deploy; see Phase 11).

---

## Phase 5: User Story 7 — Cache pricing on every Claude alias (Priority: P3)

**Goal**: Ensure every `model_name: claude-*` entry carries `cache_control_injection_points`, not just the canonical names.

**Independent Test**: For every `claude-*` alias, a repeated identical system prompt reports `cache_read_input_tokens > 0` on the second call.

### Implementation for User Story 7

- [X] T004 [US7] Audit `config/litellm-config.yaml`: list every `model_name: claude-*` entry that does NOT already have an attached `cache_control_injection_points` block. Add the same block:

  ```yaml
  cache_control_injection_points:
    - location: message
      role: system
  ```

  to each missing entry. Confirm the two Claude Code aliases (`claude-sonnet-4-5-20250929`, `claude-opus-4-5-20251101`) and the new Opus 4.7 entries from T003 all carry the block. Done signal: for every line matching `^  - model_name: claude-`, the next 4 YAML lines contain `cache_control_injection_points`. Verify with `awk` or `grep -A 5` spot-check; total count of `cache_control_injection_points:` keys MUST equal total count of `- model_name: claude-` lines.

**Checkpoint**: User Story 7 complete.

---

## Phase 6: User Story 3 — Portable infrastructure (WAF var.domain) (Priority: P2)

**Goal**: WAF rules reference the configured domain variable, not a hardcoded hostname.

**Independent Test**: `terraform -chdir=terraform plan` with a different `domain` value produces WAF expressions mentioning the new hostname.

### Implementation for User Story 3

- [X] T005 [P] [US3] Replace the three literal `llm.matthewdeaves.com` occurrences in `terraform/waf.tf` (lines 28, 34, 42) with `${var.domain}` interpolation. Done signals: `grep -c 'llm.matthewdeaves.com' terraform/waf.tf` returns 0 AND `grep -c '\${var.domain}' terraform/waf.tf` returns 3.

**Checkpoint**: User Story 3 complete.

---

## Phase 7: User Story 4 — Claude-only allowlist derived from config (Priority: P2)

**Goal**: The admin CLI derives Claude-only model allowlists from `config/litellm-config.yaml` at invocation time and fails loudly on malformed / missing config.

**Independent Test**: Adding a new `- model_name: claude-foo` entry to the YAML and running `./scripts/rockport.sh key create test --claude-only` produces a key whose `models` field contains `claude-foo` without any further edits.

### Implementation for User Story 4

- [X] T006 [P] [US4] In `scripts/rockport.sh`, replace the hardcoded `CLAUDE_MODELS='[...]'` definition at line 18 with a `claude_models()` shell function that:

  1. Reads `"$CONFIG_DIR/litellm-config.yaml"` (existing `$CONFIG_DIR` variable).
  2. Dies with a clear error via `die "Cannot read <path>"` if the file is missing or unreadable.
  3. Greps for `^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*claude-` lines, strips the prefix, trims whitespace, and optionally strips surrounding quotes (to handle `"claude-opus-4-7[1m]"` quoting).
  4. Dies with a clear error if the result is empty.
  5. Emits a JSON array via `jq -R . | jq -s -c .`.

  Update every caller of the old `$CLAUDE_MODELS` variable to call `claude_models` (command substitution). Preserve explicit error handling (no `set -e`, per Constitution VI). Done signal: `grep -c 'CLAUDE_MODELS=' scripts/rockport.sh` returns 0; `grep -c '^claude_models()' scripts/rockport.sh` returns 1; `bash -n scripts/rockport.sh` succeeds.

**Checkpoint**: User Story 4 complete.

---

## Phase 8: User Story 5 — Health endpoint requires auth (Priority: P2)

**Goal**: `/v1/videos/health` returns 401 without a Bearer token; 200 (or 503) with one; pentest suite asserts the new posture.

**Independent Test**: `curl -s -o /dev/null -w '%{http_code}' <tunnel>/v1/videos/health` returns `401`; with a valid `Authorization: Bearer <key>` header it returns `200` (healthy) or `503` (degraded).

### Implementation for User Story 5

- [X] T007 [P] [US5] In `sidecar/video_api.py`, change the `/v1/videos/health` handler signature from `def health():` (around line 404) to `def health(auth: dict = Depends(authenticate)):`. No other change. The existing `authenticate` dependency already returns `{"detail":"unauthorized"}` via `HTTPException(401)` when credentials are missing/invalid, matching the contract. Done signal: `grep -A 1 "@app.get(\"/v1/videos/health\")" sidecar/video_api.py` shows a `Depends(authenticate)` parameter within the following 2 lines.

- [X] T008 [P] [US5] Update `pentest/scripts/sidecar.sh` so the test that probes `/v1/videos/health` without auth expects HTTP `401` instead of `200`. Add a complementary assertion that the same probe WITH a valid Bearer token returns `200` or `503`. Done signal: `grep -c '/v1/videos/health' pentest/scripts/sidecar.sh` returns at least 2; `bash -n pentest/scripts/sidecar.sh` succeeds.

**Checkpoint**: User Story 5 complete.

---

## Phase 9: User Story 6 — Per-key concurrency invariant documented (Priority: P2)

**Goal**: Prevent future refactors from accidentally splitting the per-key concurrent-job counter per model or per region.

**Independent Test**: Code reviewer reading `sidecar/db.py` encounters an explicit comment stating the cross-model invariant; pentest suite continues to pass.

### Implementation for User Story 6

- [X] T009 [P] [US6] In `sidecar/db.py`, add a 2–3 line comment immediately above the `SELECT COUNT(*) FROM rockport_video_jobs WHERE api_key_hash = %s AND status IN ('pending', 'in_progress')` statement (function `insert_job_with_concurrency_check`, around line 306). The comment must state: "Invariant: count across ALL models and ALL regions per api_key_hash. Do not add a `model = %s` or region predicate — the per-key limit is global by design (see spec 016, FR-008)." Done signal: `grep -c 'Invariant: count across ALL models' sidecar/db.py` returns 1.

**Checkpoint**: User Story 6 complete.

---

## Phase 10: User Story 8 — Sidecar dependency patch level (Priority: P3)

**Goal**: psycopg2-binary at current patch release with hash-pinned lock regenerated.

**Independent Test**: `pip show psycopg2-binary` inside the sidecar venv reports `2.9.12`.

### Implementation for User Story 8

- [X] T010 [P] [US8] In `sidecar/requirements.txt`, change `psycopg2-binary==2.9.11` to `psycopg2-binary==2.9.12`. Done signal: `grep -c 'psycopg2-binary==2.9.12' sidecar/requirements.txt` returns 1; `grep -c '2.9.11' sidecar/requirements.txt` returns 0.

- [X] T011 [US8] Regenerate `sidecar/requirements.lock` using `pip-compile --generate-hashes --output-file sidecar/requirements.lock sidecar/requirements.txt` in a venv with matching Python 3.11. Done signal: `grep -E 'psycopg2-binary==2\.9\.12' sidecar/requirements.lock` returns a match AND every top-level requirement line in the lock is followed by `--hash=sha256:` entries.

**Checkpoint**: User Story 8 complete.

---

## Phase 11: User Story 9 — Release documentation accurate (Priority: P3)

**Goal**: `CLAUDE.md` reflects the new model, the new LiteLLM pin, and the Bedrock retirement calendar; auto-generated Active Technologies noise is trimmed.

**Independent Test**: A human reading `CLAUDE.md` sees Opus 4.7, LiteLLM 1.83.7, and the three retirement dates.

### Implementation for User Story 9

- [X] T012 [US9] Edit `CLAUDE.md` in these ways:

  1. Append a new top entry to "Recent Changes" summarizing feature 016: "LiteLLM 1.82.6 → 1.83.7 (patches 6 CVEs including SQL-injection on auth path); added Claude Opus 4.7 (`eu.` profile) + `claude-opus-4-7[1m]` alias; WAF rules now use `var.domain`; `--claude-only` keys derived from `litellm-config.yaml`; `/v1/videos/health` now requires Bearer auth; psycopg2-binary 2.9.11 → 2.9.12."
  2. Update the "Chat models" line (around line 101) to include "Claude (Opus 4.7 1M, Opus/Sonnet 4.6, Haiku 4.5)".
  3. Add a "Bedrock retirement calendar" subsection (under "Important Notes") listing: Titan Image v2 (`amazon.titan-image-generator-v2:0`) — EOL 2026-06-30 (kept by operator choice); Nova Canvas v1 — EOL 2026-09-30; Nova Reel v1.1 — EOL 2026-09-30.
  4. Clean up the auto-generated "Active Technologies" lines the speckit script added (lines 163–164) — trim the prose; keep one crisp line like "Bash + Python 3.11 (FastAPI) + Terraform + LiteLLM 1.83.7 on Amazon Linux 2023, PostgreSQL 15 on instance, Cloudflare Tunnel ingress" instead of the long markdown bullet the script appended.

  Done signals: `grep -c 'Claude Opus 4.7' CLAUDE.md` returns at least 1; `grep -c '1.83.7' CLAUDE.md` returns at least 1; `grep -c 'Bedrock retirement calendar' CLAUDE.md` returns 1; `grep -c '2026-06-30' CLAUDE.md` returns at least 1; `grep -c '016-security-claude-4-7-upgrade' CLAUDE.md` returns at most 1 (no duplicated entries from the update-agent-context script).

**Checkpoint**: User Story 9 complete.

---

## Phase 12: Polish — Local quality gates (covers SC-008)

**Purpose**: Run every local quality tool the repo depends on. All must exit zero before push.

- [X] T013 [P] Run `terraform -chdir=terraform fmt -check -recursive`. Done signal: exit 0 and no diff.
- [X] T014 [P] Run `terraform -chdir=terraform init -backend=false` then `terraform -chdir=terraform validate`. Done signal: both exit 0.
- [X] T015 [P] Run `shellcheck scripts/*.sh tests/*.sh pentest/pentest.sh pentest/scripts/*.sh`. Done signal: exit 0.
- [X] T016 [P] Run `pip-audit -r` against a flattened copy of `sidecar/requirements.lock` (strip `--hash` continuation lines). Done signal: exit 0.
- [X] T017 [P] Run `gitleaks detect --source . --no-banner --config .gitleaks.toml`. Done signal: exit 0.
- [X] T018 [P] Run `trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore terraform/`. Done signal: exit 0.
- [X] T019 [P] Run `checkov -d terraform/ --config-file .checkov.yaml`. Done signal: exit 0.
- [X] T020 Run `bash -n` on every edited bash script (`scripts/rockport.sh`, `pentest/scripts/sidecar.sh`). Done signal: exit 0.

**Checkpoint**: All local gates green. Ready to push.

---

## Phase 13: Polish — Deploy + smoke + pentest (covers SC-009) — MANUAL POST-MERGE

**Purpose**: Verify against a live deployment. These tasks execute post-merge, when the operator runs `rockport.sh deploy` (infrastructure is currently destroyed).

- [ ] T021 [MANUAL] Run `./scripts/rockport.sh deploy`. Done signal: deploy completes; `./scripts/rockport.sh status` reports `healthy`.
- [ ] T022 [MANUAL] Run `./tests/smoke-test.sh`. Done signal: all assertions pass, including 401 on anonymous `/v1/videos/health`.
- [ ] T023 [MANUAL] Run `./pentest/pentest.sh run rockport`. Done signal: suite reports PASS for all 13 modules.
- [ ] T024 [MANUAL] Claude-Code cache sanity: two identical chat completions against `claude-opus-4-7[1m]` return `cache_read_input_tokens > 0` on the second call.

**Checkpoint**: Live verification complete.

---

## Phase 14: Polish — Release

**Purpose**: Commit, PR, merge, tag, release.

- [ ] T025 Stage and commit all changed files with a conventional-commit message: `feat: security upgrade + Claude Opus 4.7 support`. Include the 016 feature reference in the body. Done signal: `git log -1 --oneline` shows the commit on branch `016-security-claude-4-7-upgrade`.
- [ ] T026 Push the branch: `git push -u origin 016-security-claude-4-7-upgrade`. Done signal: `git rev-parse @{u}` returns the remote sha matching local.
- [ ] T027 Open PR: `gh pr create --title "feat: security upgrade + Claude Opus 4.7 support" --body "<summary referencing spec 016>" --base main`. Done signal: `gh pr view --json state -q .state` returns `OPEN`.
- [ ] T028 After CI passes, merge: `gh pr merge --squash --admin --delete-branch`. Done signal: `gh pr view --json state -q .state` returns `MERGED`; branch deleted remotely.
- [ ] T029 On local `main`: `git checkout main && git pull`. Done signal: `git log -1 --oneline` shows the squash-merge commit.
- [ ] T030 Tag the release: `git tag -a v1.2.0 -m "Rockport v1.2.0 — security upgrade + Claude Opus 4.7"` and `git push origin v1.2.0`. Done signal: `gh release view v1.2.0 --json tagName -q .tagName` returns `v1.2.0` once the release workflow completes.

**Checkpoint**: Release live.

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 (setup) → Phase 2 (foundational, empty by design).
- Phases 3–11 (user stories) all start after Phase 2. Many are parallelizable — see below.
- Phase 12 (local quality gates) depends on Phases 3–11 being complete.
- Phase 13 (deploy + smoke + pentest) depends on Phase 14's merge and the operator's manual deploy.
- Phase 14 (release) depends on Phase 12.

### Parallel Opportunities

After the P1 MVPs (T002, T003) complete, the following are fully parallel because they touch disjoint files:

- T004 (config/litellm-config.yaml cache injections on remaining claude aliases) — same file as T003 but non-overlapping entries, so safe to do after T003.
- T005 (terraform/waf.tf)
- T006 (scripts/rockport.sh)
- T007 (sidecar/video_api.py)
- T008 (pentest/scripts/sidecar.sh)
- T009 (sidecar/db.py)
- T010 (sidecar/requirements.txt) — must precede T011 (requirements.lock regeneration).

T012 (CLAUDE.md) is also a disjoint file but intentionally scheduled near the end so the summary reflects the final set of changes.

Phase 12's quality gates (T013–T020) are all parallelizable.

### Within Each User Story

- Each story's primary task has its own done signal; no within-story ordering is required for single-task stories.
- US5 (T007 → T008) can run in parallel — different files, no coupling.
- US8 (T010 → T011) must be sequential — T011 consumes the updated T010 output.

---

## Implementation Strategy

### MVP (Phases 1 + 3 + 4)

- T001 setup
- T002 LiteLLM pin (CVE fix)
- T003 Claude Opus 4.7 entries

This is the minimum viable upgrade: the current destroyed instance, re-deployed from this state, has a patched proxy and a functioning Claude Code model.

### Full Feature Delivery

Continue through Phases 5–11, then Phases 12–14. Per the spec, this is the full scope of feature 016.

---

## Notes

- No new automated tests are added. Smoke-test + pentest cover the change surface.
- Constitution VI applies to every bash edit — explicit error handling only, no `set -e`.
- Done signals are deliberately machine-checkable so `/speckit.analyze` and `/speckit.implement` can verify coverage without ambiguity.
