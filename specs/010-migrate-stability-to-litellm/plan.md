# Implementation Plan: Migrate Stability AI Image Endpoints to LiteLLM Native

**Branch**: `010-migrate-stability-to-litellm` | **Date**: 2026-03-19 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/010-migrate-stability-to-litellm/spec.md`

## Summary

Migrate 13 Stability AI image editing operations from the custom sidecar (FastAPI on port 4001) to LiteLLM's native `/v1/images/edits` endpoint. LiteLLM 1.82.3 has built-in support for all 13 operations via its `bedrock/image_edit/stability_transformation.py` module. This eliminates ~60% of sidecar image code, simplifies WAF/tunnel infrastructure, and unifies spend tracking. The 3 Nova Canvas endpoints (variations, background-removal, outpaint) and all video endpoints remain on the sidecar since LiteLLM does not support these.

## Technical Context

**Language/Version**: Python 3.11 (sidecar), HCL (Terraform), YAML (LiteLLM config), Bash (smoke tests, CLI)
**Primary Dependencies**: LiteLLM 1.82.3, FastAPI, boto3, Cloudflare Terraform provider
**Storage**: PostgreSQL 15 (LiteLLM spend tracking — no schema changes needed)
**Testing**: Bash smoke tests (`tests/smoke-test.sh`), manual verification via curl
**Target Platform**: Linux EC2 t3.small (Amazon Linux 2023)
**Project Type**: Infrastructure/proxy service
**Performance Goals**: N/A — single user, no performance-sensitive changes
**Constraints**: 2GB RAM (t3.small), sidecar MemoryMax 256MB
**Scale/Scope**: Single operator, 13 model configs added, 13 endpoints removed, ~6 files modified

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure. Removes sidecar complexity. No cost impact. |
| II. Security | PASS | Auth moves from custom sidecar code to LiteLLM's built-in key system — strictly better. |
| III. LiteLLM-First | PASS | **This migration directly implements Principle III** — replacing custom sidecar code with LiteLLM native capability. |
| IV. Scope Containment | PASS | Removing code, not adding features. Stays within proxy scope. |
| V. AWS London + Cloudflare | PASS | No new regions or services. Stability AI models stay in us-west-2 via LiteLLM config. |

**Gate result: ALL PASS** — this migration is a direct expression of the constitution's LiteLLM-First principle.

## Project Structure

### Documentation (this feature)

```text
specs/010-migrate-stability-to-litellm/
├── plan.md              # This file
├── research.md          # Phase 0: LiteLLM image_edit research
├── data-model.md        # Phase 1: Model config and routing changes
├── quickstart.md        # Phase 1: Verification guide
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (files modified)

```text
config/
└── litellm-config.yaml          # Add 13 Stability AI image_edit model entries

sidecar/
└── image_api.py                 # Remove 13 Stability AI endpoints + helpers

terraform/
├── tunnel.tf                    # Update ingress rules for new routing
└── waf.tf                       # Add /v1/images/edits, remove sidecar paths

tests/
└── smoke-test.sh                # Replace sidecar Stability tests with /v1/images/edits tests

scripts/
└── rockport.sh                  # No changes needed (no Stability AI references)

docs/
├── rockport_architecture_overview.svg  # Update sidecar box, add LiteLLM image_edit flow
└── rockport_request_dataflow.svg       # Update image routing paths

CLAUDE.md                        # Update image service documentation
README.md                        # Update Stability AI endpoint documentation
```

**Structure Decision**: This is a modification-only feature — no new files created, no new directories. All changes are edits to existing files within the established project structure.

## Complexity Tracking

> No constitution violations — table not needed.
