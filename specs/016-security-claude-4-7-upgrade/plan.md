# Implementation Plan: Security Upgrade and Claude 4.7 Support

**Branch**: `016-security-claude-4-7-upgrade` | **Date**: 2026-04-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/016-security-claude-4-7-upgrade/spec.md`

## Summary

Bump the LiteLLM proxy pin from 1.82.6 to 1.83.7 to close six high/critical advisories (including a SQL injection on the authenticated request path); add Claude Opus 4.7 to the model catalog using the EU cross-region inference profile, including the literal Claude-Code runtime identifier `claude-opus-4-7[1m]`; fix a hardcoded hostname in the WAF allowlist; derive the Claude-only key allowlist from the proxy config at runtime; authenticate the video-sidecar health endpoint; and update sidecar dependency patch levels and project documentation. No new AWS resources, no new services, no schema changes.

## Technical Context

**Language/Version**: Bash (CLI, bootstrap, smoke, pentest); Python 3.11 (sidecar); HCL (Terraform 1.14); YAML (LiteLLM config)
**Primary Dependencies**: LiteLLM proxy 1.82.6 → **1.83.7** (exact pin); FastAPI (unchanged); psycopg2-binary 2.9.11 → **2.9.12**; httpx 0.28.1 (unchanged); Pillow 12.2.0 (unchanged); Prisma 0.11.0 (unchanged); AWS provider 6.41.0 (unchanged); Cloudflare provider `~> 5.0` (unchanged); cloudflared 2026.3.0 (unchanged)
**Storage**: PostgreSQL 15 on the instance — **no schema changes**. `rockport_video_jobs` and LiteLLM's Prisma-managed tables unchanged.
**Testing**: `tests/smoke-test.sh` (post-deploy bash), `pentest/pentest.sh run rockport` (13-module security suite). CI: terraform fmt/validate, shellcheck, gitleaks, trivy, pip-audit, checkov.
**Target Platform**: Amazon Linux 2023 on EC2 `t3.small` (eu-west-2); Cloudflare Tunnel ingress.
**Project Type**: Single-project bash + Terraform + Python-sidecar. Matches existing Rockport structure.
**Performance Goals**: Unchanged. Single-instance throughput (60 rpm/key default). No new hot paths.
**Constraints**: 2 GB RAM instance — new LiteLLM release must not regress memory footprint beyond existing 1280 MB MemoryMax (no such regression expected in a patch-level bump within 1.x). Cache injection must continue to hit Bedrock's 1024-token minimum for caching to register.
**Scale/Scope**: One deployed instance; operator + Claude Code users. ~36 model entries in the LiteLLM config; 2 new entries added by this feature (`claude-opus-4-7`, `claude-opus-4-7[1m]`).

## Constitution Check

All six constitutional principles pass on first evaluation:

| Principle | Status | Note |
|---|---|---|
| I. Cost Minimization | PASS | Zero new AWS resources, zero new services. £0 delta on infra spend. |
| II. Security | PASS | Patches six known-exploitable CVEs; adds Bearer-auth requirement on a previously anonymous endpoint; removes hardcoded hostname drift risk. Net posture strictly improves. |
| III. LiteLLM-First | PASS | All model additions are config-only. No custom middleware. The CLI helper (Claude-only allowlist derivation) is ergonomics over LiteLLM's `/key/generate`, not a replacement. |
| IV. Scope Containment | PASS | Each change is either a defect fix or a model addition for the existing core use case (Claude Code → Rockport → Bedrock). No new surface area. Twelve Labs / Pixtral / Nova 2 Pro deliberately deferred. |
| V. AWS London + Cloudflare | PASS | No region, provider, storage, or secrets-management changes. eu-west-2 remains primary for chat; Bedrock cross-region profiles for US-only and image/video unchanged. |
| VI. Explicit Bash Error Handling | PASS | `claude_models()` helper will follow the existing `die "message"` pattern used throughout `scripts/rockport.sh`. No `set -e` / `set -u` / `set -o pipefail`. |

No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/016-security-claude-4-7-upgrade/
├── plan.md                       # This file
├── spec.md                       # Feature specification (with Clarifications)
├── research.md                   # Phase 0 — decision record
├── data-model.md                 # Phase 1 — (trivial: no schema change)
├── quickstart.md                 # Phase 1 — deploy/verify steps
├── contracts/
│   └── video-health-endpoint.md  # Phase 1 — 200→401 contract change
├── checklists/
│   └── requirements.md           # Spec quality checklist (all green)
└── tasks.md                      # Phase 2 — /speckit.tasks output
```

### Source Code (repository — files touched)

```text
terraform/
├── variables.tf                  # MODIFY: litellm_version 1.82.6 → 1.83.7
└── waf.tf                        # MODIFY: 3× llm.matthewdeaves.com → ${var.domain}

config/
└── litellm-config.yaml           # MODIFY: +2 Opus 4.7 entries; cache_control_injection_points on all claude-* aliases

scripts/
└── rockport.sh                   # MODIFY: replace hardcoded CLAUDE_MODELS with claude_models() helper

sidecar/
├── video_api.py                  # MODIFY: Depends(authenticate) on /v1/videos/health
├── db.py                         # MODIFY: add comment documenting cross-model concurrency invariant
├── requirements.txt              # MODIFY: psycopg2-binary 2.9.11 → 2.9.12
└── requirements.lock             # REGENERATE: pip-compile --generate-hashes

pentest/scripts/
└── sidecar.sh                    # MODIFY: health assertion 200 → 401 (unauth case)

CLAUDE.md                         # MODIFY: Recent Changes, chat models, +Bedrock retirement calendar
```

**Structure Decision**: Existing Rockport layout — no new top-level directories. Every change lands in an already-present file except for the regenerated `sidecar/requirements.lock` which replaces the current lock.

## Complexity Tracking

None. All gates pass without justification.

---

## Phase 0 Output

See [research.md](./research.md).

## Phase 1 Output

See [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md).

## Post-Design Constitution Re-Check

All six principles still pass after the design phase. No violations introduced by the concrete file-level plan.

## Rollback Plan

The feature is fully reversible via `git revert` on the squash-merge commit followed by `./scripts/rockport.sh upgrade`:

1. `git revert <merge-sha>` restores LiteLLM pin, config, sidecar code, pentest, and docs.
2. `./scripts/rockport.sh upgrade` SSH-deploys the reverted artifacts via SSM and restarts LiteLLM + video sidecar.
3. LiteLLM 1.83.7 → 1.82.6 Prisma migration delta is additive-only (no destructive migrations in this patch window), so no database action is required on downgrade.
4. SSM parameters and Cloudflare state are unchanged by this feature, so nothing external to roll back.

Estimated rollback time from decision to service health: under 5 minutes.
