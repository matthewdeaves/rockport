# Quickstart: Security Audit Fixes

**Branch**: `011-security-audit-fixes` | **Date**: 2026-03-20

## Overview

This feature implements 14 security hardening fixes across three layers:
1. **Sidecar** (Python/FastAPI) — race condition, body size limits, error sanitization, authorization, validation
2. **Terraform** (HCL) — IAM scoping, CloudTrail, SSM document scoping
3. **Scripts** (Bash) — checksum verification, log permissions, pip hash pinning, state bucket hardening

## Prerequisites

- Python 3.11 with pip-tools (`pip install pip-tools`) for generating requirements.lock
- Terraform with AWS and Cloudflare providers configured
- Access to the rockport AWS account

## Key Implementation Notes

### CRIT-1: Race Condition Fix (video_api.py + db.py)

The current flow is: Bedrock → DB insert → check limit. The fix reverses this to: DB reserve → Bedrock → update ARN.

This requires:
1. Making `invocation_arn` nullable in the `rockport_video_jobs` table schema
2. Adding `update_job_arn()` and `mark_job_failed()` DB functions
3. Restructuring `create_video()` to reserve first, invoke second

### Body Size Middleware (video_api.py)

Add raw ASGI middleware (not `BaseHTTPMiddleware` which buffers). Check `Content-Length` header against 40MB limit. For chunked transfers, stream-count and abort.

### Error Sanitization (video_api.py + image_api.py)

Replace `f"...failed: {error_msg}"` patterns with generic messages. Log full errors with a reference UUID for correlation.

### Requirements Lock File

Generate with: `cd sidecar && pip-compile --generate-hashes requirements.txt -o requirements.lock`

Update bootstrap.sh to use: `pip3.11 install --require-hashes -r /tmp/rockport-artifact/sidecar/requirements.lock`

## Testing

After implementation, verify each fix against its acceptance scenarios in spec.md. The smoke-test.sh should be extended to cover:
- Video generation still works (CRIT-1 didn't break the happy path)
- Image generation still works (error sanitization didn't break responses)
- All configured models are accessible (IAM scoping didn't block required models)

## Deployment Order

Deploy in this order to minimize risk:
1. **Sidecar changes** — CRIT-1, body size, error sanitization, claude-only, seed validation (application code, no infra changes)
2. **IAM changes** — model scoping, SSM scoping (Terraform apply, verify models still work)
3. **CloudTrail** — new resource, no impact on existing functionality
4. **Bootstrap changes** — checksum verification, pip hashing, log permissions (only affects new instance creation)
5. **CLI changes** — state bucket DenyNonSSL (only affects new `init` runs)
