# Implementation Plan: LiteLLM Bedrock Proxy

**Branch**: `001-litellm-bedrock-proxy` | **Date**: 2026-03-13 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-litellm-bedrock-proxy/spec.md`

## Summary

Deploy a LiteLLM proxy on a single EC2 instance behind a Cloudflare Tunnel, giving Claude Code access to Bedrock models (Anthropic, DeepSeek, Qwen, Kimi, Amazon Nova) through one HTTPS endpoint. Terraform manages all infrastructure. A bash CLI (`rockport.sh`) wraps LiteLLM's admin API for day-to-day operations. GitHub Actions provides CI/CD with terraform plan on PR, apply on merge, and post-deploy smoke tests. Remote state in S3 enables CI/CD and multi-machine workflows.

## Technical Context

**Language/Version**: Terraform HCL 1.14+, Bash 5.x, Python 3.11 (on instance only, for LiteLLM)
**Primary Dependencies**: LiteLLM 1.82.x, PostgreSQL 15, cloudflared, Prisma (Python client)
**Storage**: PostgreSQL 15 (local on instance) for virtual keys/spend; S3 for Terraform state
**Testing**: Shell-based smoke tests (`tests/smoke-test.sh`), shellcheck for linting, `terraform validate`
**Target Platform**: Amazon Linux 2023 (x86_64) on EC2 t3.small
**Project Type**: Infrastructure + proxy (no custom application code)
**Performance Goals**: <100ms proxy overhead on streaming responses
**Constraints**: <£15/month infrastructure cost, single instance, no inbound ports
**Scale/Scope**: 1 operator, <10 users, ~8 hours/day Claude Code usage

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Gate | Status | Notes |
|------|--------|-------|
| I. Cost <£100/month, target <£15 | PASS | t3.small ~£10.53, EBS ~£1.60, snapshots ~£1-2, CF Tunnel free, S3 state <£0.01 |
| II. No inbound ports, tunnel-only | PASS | SG has zero inbound rules, cloudflared outbound tunnel |
| II. Master key in SSM, not source | PASS | `/rockport/master-key` in SSM SecureString |
| III. LiteLLM-first, no custom code | PASS | Only IaC, config, bootstrap script, CLI wrapper |
| III. Admin UI disabled | PASS | `disable_admin_ui: true` in config |
| IV. Scope containment | PASS | No dashboard, billing, logging, RAG, frontend |
| V. AWS eu-west-2 + Cloudflare | PASS | All resources in eu-west-2, DNS on Cloudflare |
| V. IaC single-command deploy | PASS | `terraform apply` or `rockport deploy` |
| V. Systemd Restart=always | PASS | litellm, postgresql, cloudflared all auto-restart |
| V. CI/CD via GitHub Actions | PASS | validate.yml (lint), deploy.yml (plan/apply/smoke) |

No violations. No complexity tracking needed.

## Project Structure

### Documentation (this feature)

```text
specs/001-litellm-bedrock-proxy/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── contracts/           # Phase 1 output
    └── litellm-api.md   # API surface exposed to Claude Code
```

### Source Code (repository root)

```text
terraform/
├── main.tf              # EC2 instance, IAM roles, security group
├── tunnel.tf            # Cloudflare Tunnel, DNS, SSM token
├── snapshots.tf         # DLM daily EBS snapshots
├── monitoring.tf        # Budget alarm, auto-recovery
├── variables.tf         # Input variables
├── outputs.tf           # Instance ID, tunnel URL, SSM command
├── providers.tf         # AWS + Cloudflare providers
├── versions.tf          # Required provider versions
└── backend.tf           # S3 remote state (new)

config/
├── litellm-config.yaml  # LiteLLM model routing + settings
├── litellm.service      # systemd unit for LiteLLM
├── cloudflared.service  # systemd unit for cloudflared
├── postgresql-tuning.conf # PostgreSQL memory tuning
└── claude-code-settings.json # Template for client machines

scripts/
├── bootstrap.sh         # EC2 user_data — full instance setup
├── rockport.sh          # Admin CLI (key mgmt, status, deploy, spend, config push)
└── setup.sh             # Dev machine setup (Ubuntu + macOS)

tests/
└── smoke-test.sh        # Post-deploy verification

.github/workflows/
├── validate.yml         # PR: terraform fmt/validate, shellcheck
└── deploy.yml           # Main: terraform apply, smoke tests
```

**Structure Decision**: No `src/` directory — this project has no custom application code. All logic is in Terraform HCL, bash scripts, and YAML configuration. The repository root organizes by concern: `terraform/` for infrastructure, `config/` for service configuration, `scripts/` for operational tooling.
