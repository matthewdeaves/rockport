# Release-Readiness Checklist: 016-security-claude-4-7-upgrade

**Purpose**: Operational gate list for the overnight implement → quality → release → deploy sequence. Each item is a verifiable assertion; tick when the stated condition is observably true.
**Created**: 2026-04-21
**Feature**: [spec.md](../spec.md)

**Note**: This is an operational release runbook (distinct from [requirements.md](./requirements.md), which checks the *spec's* quality). IDs continue from the requirements checklist's last-used prefix but live in their own file for clarity.

## Implement Phase

- [X] CHK001 `grep -c '"1.83.7"' terraform/variables.tf` returns ≥ 1 and `grep -c '"1.82.6"' terraform/variables.tf` returns 0 (LiteLLM pin bumped, CVE-class advisories closed).
- [X] CHK002 `grep -c 'bedrock/eu.anthropic.claude-opus-4-7' config/litellm-config.yaml` returns ≥ 2 (Opus 4.7 canonical + `[1m]` alias both target the EU inference profile).
- [X] CHK003 Every `- model_name: claude-*` line in `config/litellm-config.yaml` is followed within 6 lines by a `cache_control_injection_points:` block (no Claude-family alias loses cache pricing).
- [X] CHK004 `grep -c 'llm.matthewdeaves.com' terraform/waf.tf` returns 0 and `grep -c '\${var.domain}' terraform/waf.tf` returns 3 (hardcoded hostname eliminated).
- [X] CHK005 `grep -c 'CLAUDE_MODELS=' scripts/rockport.sh` returns 0 and `grep -c '^claude_models()' scripts/rockport.sh` returns 1 (helper replaces static allowlist).
- [X] CHK006 `bash -n scripts/rockport.sh` and `bash -n pentest/scripts/sidecar.sh` both exit 0 (syntactic validity after edits).
- [X] CHK007 `grep -A1 '@app.get("/v1/videos/health")' sidecar/video_api.py` includes a `Depends(authenticate)` parameter (health endpoint now authenticated).
- [X] CHK008 `grep -c 'Invariant: count across ALL models' sidecar/db.py` returns 1 (cross-model concurrency invariant documented in code).
- [X] CHK009 `grep -c 'psycopg2-binary==2.9.12' sidecar/requirements.txt` returns 1 and `grep -c 'psycopg2-binary==2.9.12' sidecar/requirements.lock` returns 1 with `--hash=sha256:` lines (dependency and hash-pinned lock aligned).
- [X] CHK010 `pentest/scripts/sidecar.sh` contains at least one `[PASS]`/`[FAIL]` assertion explicitly testing that unauthenticated `/v1/videos/health` returns HTTP 401 (security posture reflected in the security suite).
- [X] CHK011 `CLAUDE.md` contains strings "Claude Opus 4.7", "1.83.7", and "Bedrock retirement calendar"; contains no duplicate entries for feature 016 (docs accurate, no auto-generated noise).

## Local Quality Gates

- [X] CHK012 `terraform -chdir=terraform fmt -check -recursive` exits 0.
- [X] CHK013 `terraform -chdir=terraform validate` exits 0.
- [X] CHK014 `shellcheck scripts/*.sh tests/*.sh pentest/pentest.sh pentest/scripts/*.sh` exits 0.
- [X] CHK015 `pip-audit` against the regenerated `sidecar/requirements.lock` exits 0.
- [X] CHK016 `gitleaks detect --source . --no-banner --config .gitleaks.toml` exits 0 (no secret leaked in the change set).
- [X] CHK017 `trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore terraform/` exits 0.
- [X] CHK018 `checkov -d terraform/ --config-file .checkov.yaml` exits 0.

## Release Hygiene

- [ ] CHK019 Squash-merge commit landed on `main`; `gh pr view <num> --json state -q .state` returns `MERGED`; branch `016-security-claude-4-7-upgrade` deleted remotely.
- [ ] CHK020 Tag `v1.2.0` exists locally and on origin; `gh release view v1.2.0 --json tagName -q .tagName` returns `v1.2.0` after the release workflow runs (GitHub release auto-created).
- [ ] CHK021 CI `validate` + `security-scan` jobs on the merge commit are green.

## Post-Merge Live Verification (on wake-up)

- [ ] CHK022 `./scripts/rockport.sh deploy` completes cleanly from the destroyed-state baseline; `status` returns `healthy` within 5 minutes.
- [ ] CHK023 `./tests/smoke-test.sh` all assertions pass, including: `/v1/models` lists both `claude-opus-4-7` and `claude-opus-4-7[1m]`; unauthenticated `/v1/videos/health` returns 401.
- [ ] CHK024 Two identical chat completions against `claude-opus-4-7[1m]` (>1024-token system prompt) yield `cache_read_input_tokens > 0` on the second call.
- [ ] CHK025 `./pentest/pentest.sh run rockport` reports PASS for every module, including the updated sidecar assertion.

## Notes

- Mark items complete as the condition becomes true (tool exit code, grep result, or observed response).
- The overnight run completes through CHK021. CHK022–CHK025 require the operator to run `deploy` after wake-up (infrastructure is currently destroyed).
- If any item fails, stop and diagnose — do not proceed to the next item.
