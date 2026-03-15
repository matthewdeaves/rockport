# Implementation Plan: Image Generation via Bedrock

**Branch**: `002-image-generation` | **Date**: 2026-03-15 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-image-generation/spec.md`

## Summary

Add image generation (text-to-image, image-to-image) to Rockport by configuring LiteLLM with Bedrock image models (Nova Canvas, Titan Image Gen v2, SD3 Large) routed to us-west-2. Introduce per-key model restrictions so Claude Code keys only access Anthropic models while general keys access everything. Update WAF, IAM, CLI tooling, and smoke tests.

## Technical Context

**Language/Version**: Bash (CLI), HCL (Terraform), YAML (LiteLLM config)
**Primary Dependencies**: LiteLLM 1.82.2, Terraform, Cloudflare provider, AWS provider
**Storage**: PostgreSQL (existing, no changes — key model restrictions stored by LiteLLM)
**Testing**: `tests/smoke-test.sh` (bash, curl-based)
**Target Platform**: EC2 Amazon Linux 2023 (eu-west-2)
**Project Type**: Infrastructure/CLI
**Performance Goals**: N/A (image generation is inherently slow — seconds per image)
**Constraints**: No additional infrastructure cost. LiteLLM-first (no custom code beyond CLI/config).
**Scale/Scope**: Single operator, personal use

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No new infrastructure. Image gen cost is Bedrock token charges only. |
| II. Security | PASS | Same auth model. WAF adds one allowed path. IAM adds one region. |
| III. LiteLLM-First | PASS | Image gen uses LiteLLM's built-in `/v1/images/generations`. Key restrictions use built-in `models` parameter. No custom code. |
| IV. Scope Containment | PASS | Bedrock-only image models. No custom hosting, no new services. |
| V. AWS London + Cloudflare | PASS (with note) | EC2 stays in eu-west-2. Image model API calls route to us-west-2 — config only, no infra change. |

**Post-design re-check**: All gates still pass. No violations.

## Project Structure

### Documentation (this feature)

```text
specs/002-image-generation/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── image-generation.md
│   └── key-management.md
└── tasks.md
```

### Source Code (repository root)

```text
config/
└── litellm-config.yaml       # Add image model entries

terraform/
├── main.tf                    # Add us-west-2 to bedrock_regions
└── waf.tf                     # Add /v1/images/generations to allowlist

scripts/
└── rockport.sh                # Key create --claude-only, setup-claude model restriction,
                               #   start command health-wait, alias suggestion

tests/
└── smoke-test.sh              # Add image generation test
```

**Structure Decision**: No new files. All changes are to existing config, Terraform, CLI, and test files.

## Complexity Tracking

No constitution violations. No complexity tracking needed.
