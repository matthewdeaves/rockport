# Implementation Plan: Security Audit Fixes

**Branch**: `011-security-audit-fixes` | **Date**: 2026-03-20 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/011-security-audit-fixes/spec.md`

## Summary

Implement 14 security fixes identified in the security audit (GitHub Issues #7–#10). The fixes span three layers: sidecar application code (race condition, error sanitization, body size limits, input validation, authorization), Terraform IAM policies (model scoping, SSM scoping, CloudTrail), and bootstrap/CLI scripts (checksum verification, log permissions, pip hash pinning, state bucket hardening). All changes are hardening of existing functionality — no new features or user-facing behavior changes.

## Technical Context

**Language/Version**: Python 3.11 (sidecar), HCL/Terraform (infrastructure), Bash (scripts)
**Primary Dependencies**: FastAPI, uvicorn, boto3, Pillow, psycopg2, pydantic, httpx
**Storage**: PostgreSQL 15 (on-instance, LiteLLM + video job tracking)
**Testing**: smoke-test.sh (post-deploy), manual acceptance testing per user story
**Target Platform**: Linux (Amazon Linux 2023, EC2 t3.small)
**Project Type**: Web service (API proxy + sidecar)
**Performance Goals**: No regression — existing request latency and throughput unchanged
**Constraints**: 2GB RAM (t3.small), 256MB MemoryMax (sidecar), 1280MB MemoryMax (LiteLLM)
**Scale/Scope**: Single operator, single instance. 14 discrete fixes across 8 files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | **PASS** | CloudTrail adds ~$2/month for management events. All other fixes are zero-cost. Well under £100/month. |
| II. Security | **PASS** | All changes improve security posture. No new attack surface introduced. |
| III. LiteLLM-First | **PASS** | No LiteLLM reimplementation. Sidecar changes are within the "what LiteLLM does NOT handle" scope (video/image sidecar, bootstrap, IaC). |
| IV. Scope Containment | **PASS** | No new features. Strictly hardening existing functionality per audit findings. |
| V. AWS London + Cloudflare | **PASS** | CloudTrail in eu-west-2. No new services beyond CloudTrail + S3 bucket for trail storage. |

## Project Structure

### Documentation (this feature)

```text
specs/011-security-audit-fixes/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (files modified)

```text
sidecar/
├── video_api.py         # CRIT-1 fix, body size middleware, error sanitization, claude-only check, seed validation
├── image_api.py         # Error sanitization
├── db.py                # Make invocation_arn nullable for slot reservation pattern
└── requirements.lock    # NEW: hashed lock file for pip --require-hashes

terraform/
├── main.tf              # Scope bedrock IAM to model families, scope ssm:PutParameter
├── deployer-policies/
│   └── iam-ssm.json     # Scope SSM documents to AWS-RunShellScript
├── cloudtrail.tf        # NEW: CloudTrail trail + S3 bucket
└── deployer-policies/
    └── monitoring-storage.json  # Add CloudTrail permissions for deployer

scripts/
├── bootstrap.sh         # Cloudflared checksum, artifact checksum, log permissions, pip --require-hashes
└── rockport.sh          # DenyNonSSL bucket policy on state bucket init

config/
└── rockport-video.service  # (no changes needed — MemoryMax stays at 256MB)
```

**Structure Decision**: No new directories or structural changes. All fixes modify existing files in-place, with the exception of `sidecar/requirements.lock` (new hashed lock file) and `terraform/cloudtrail.tf` (new Terraform resource file).
