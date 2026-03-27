# Implementation Plan: OPS - Fix ThrottlingException Masking & IAM Permissions

**Branch**: `014-ops-throttle-iam-fix` | **Date**: 2026-03-27 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/014-ops-throttle-iam-fix/spec.md`

## Summary

Fix two operational issues found during 2026-03-27 infrastructure review: (1) Bedrock ThrottlingException errors are masked as HTTP 502 in the sidecar — they should return 429 so clients can implement backoff. (2) The deployer IAM policy is missing read permissions for Lambda logs and CloudTrail events, blocking operational diagnostics.

## Technical Context

**Language/Version**: Python 3.11 (sidecar), JSON (IAM policy)
**Primary Dependencies**: FastAPI, boto3/botocore, httpx
**Storage**: PostgreSQL (video job status tracking)
**Testing**: smoke-test.sh (43 assertions), manual IAM verification
**Target Platform**: Linux EC2 (Amazon Linux 2023, t3.small)
**Project Type**: Web service (proxy sidecar)
**Performance Goals**: N/A (error path only, no throughput impact)
**Constraints**: 256MB MemoryMax for sidecar, 6144-byte IAM policy size limit
**Scale/Scope**: 2 Python files + 1 JSON policy file

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure, no cost increase |
| II. Security | PASS | IAM additions are read-only, scoped to rockport resources |
| III. LiteLLM-First | PASS | Changes are in the sidecar (custom code that exists because LiteLLM cannot handle image/video generation natively) |
| IV. Scope Containment | PASS | Bug fix + permission gap, no new features |
| V. AWS London + Cloudflare | PASS | No region or provider changes |
| VI. Explicit Bash Error Handling | PASS | No bash changes in this spec |

## Project Structure

### Documentation (this feature)

```text
specs/014-ops-throttle-iam-fix/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
sidecar/
├── image_api.py         # 3 ClientError catch blocks to update (variations, background-removal, outpaint)
└── video_api.py         # 1 ClientError catch block to update (start_async_invoke)

terraform/
└── deployer-policies/
    └── monitoring-storage.json  # Add FilterLogEvents, DescribeLogStreams, LookupEvents
```

**Structure Decision**: No new files. All changes are modifications to existing files.
