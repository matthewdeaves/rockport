# Implementation Plan: Security Hardening

**Branch**: `007-security-hardening` | **Date**: 2026-03-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/007-security-hardening/spec.md`

## Summary

Six validated security issues across IAM policy, edge authentication, systemd sandboxing, database auth, idle monitoring, and concurrency control. All changes are configuration or infrastructure — no new application code beyond a single-function change in the video sidecar's database layer.

## Technical Context

**Language/Version**: Terraform (HCL) + Bash + Python 3.11 (sidecar only)
**Primary Dependencies**: Cloudflare provider ~> 5.0, AWS provider ~> 6.0, psycopg2 (sidecar)
**Storage**: PostgreSQL 15 (on-instance)
**Testing**: Bash smoke tests (`tests/smoke-test.sh`), manual IAM policy simulation
**Target Platform**: AWS EC2 (Amazon Linux 2023), Cloudflare Zero Trust
**Project Type**: Infrastructure / configuration hardening
**Performance Goals**: No performance impact — all changes are security policy or config
**Constraints**: t3.small (2GB RAM), £100/month budget cap, no new AWS services
**Scale/Scope**: Single instance, ~10-20 video jobs/day, 1 operator

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new AWS services. CloudWatch alarm is free tier (first 10 alarms free). Cloudflare Access service tokens are free on all plans. |
| II. Security | PASS | All changes directly improve security posture. |
| III. LiteLLM-First | PASS | No custom auth code. Cloudflare Access is edge-level, independent of LiteLLM. Video sidecar change is a database-layer fix, not auth logic. |
| IV. Scope Containment | PASS | No new features. Hardening existing infrastructure only. |
| V. AWS London + Cloudflare | PASS | All changes use existing providers (AWS, Cloudflare). No new regions or services. |

**Gate result: PASS** — no violations.

## Project Structure

### Documentation (this feature)

```text
specs/007-security-hardening/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (minimal — no new entities)
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
terraform/
├── deployer-policies/
│   └── iam-ssm.json          # FR-001/002: Add IAM condition to restrict AttachRolePolicy
├── access.tf                  # FR-003/004: New file — Cloudflare Access application + service token + outputs
├── idle.tf                    # FR-007/008: Add Lambda error alarm + CPU metric check

config/
├── litellm.service            # FR-005: Add 6 systemd hardening directives
├── cloudflared.service        # FR-005: Add 6 systemd hardening directives
└── rockport-video.service     # FR-005: Add 6 systemd hardening directives

scripts/
└── bootstrap.sh               # FR-006: Change md5 → scram-sha-256

sidecar/
├── db.py                      # FR-009: Atomic count-then-insert with advisory lock
└── video_api.py               # FR-009: Call new atomic function

tests/
└── smoke-test.sh              # FR-010: Verify existing tests still pass
```

**Structure Decision**: All changes are edits to existing files except `terraform/access.tf` (new file for Cloudflare Access resources, keeping tunnel.tf focused on tunnel config).
