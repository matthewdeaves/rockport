# Tasks: LiteLLM Bedrock Proxy

**Input**: Design documents from `/specs/001-litellm-bedrock-proxy/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/api.md, quickstart.md

**Tests**: Smoke tests only (post-deploy curl checks). No unit tests — no custom application code.

**Organization**: Tasks grouped by user story. US3 (Deploy) comes before US1/US2 (Claude Code access) because deployment is the prerequisite for all end-user functionality. Phases 7-8 cover CI/CD and GitHub repo setup added post-MVP.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

## Operator Prerequisites (before any task)

These are NOT implementation tasks — they are manual steps the admin completes once:

1. **AWS CLI** installed and configured with credentials for the target account (`aws configure` or env vars `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). Needed for: `terraform apply`, `rockport` CLI, SSM sessions.
2. **Session Manager plugin** installed (`aws ssm start-session` must work). Needed for: shell access to the instance, `rockport logs`, `rockport upgrade`.
3. **Terraform CLI** installed (v1.14+). Needed for: all infrastructure provisioning.
4. **Cloudflare API token** with Tunnel:Edit and DNS:Edit permissions, exported as `CLOUDFLARE_API_TOKEN`. Needed for: Terraform Cloudflare provider.
5. **Bedrock model access** enabled in `eu-west-2` via AWS Console. Needed for: LiteLLM to call Bedrock.
6. **LiteLLM master key** stored in SSM before first deploy: `aws ssm put-parameter --name "/rockport/master-key" --value "sk-$(openssl rand -hex 24)" --type SecureString --region eu-west-2`

AWS credentials are used at two stages:
- **Build time**: Terraform uses them to provision all AWS + Cloudflare resources
- **Run time**: The `rockport` CLI uses them to fetch the master key from SSM, start SSM sessions, and run Terraform commands

---

## Phase 1: Setup

**Purpose**: Project directory structure, Terraform initialization, and repo hygiene

- [x] T001 Create project directory structure (`terraform/`, `config/`, `scripts/`, `tests/`) and .gitignore (ignore `terraform/.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars` with secrets; commit `.terraform.lock.hcl`)
- [x] T002 Create terraform/providers.tf with AWS (`eu-west-2`) and Cloudflare provider configuration
- [x] T003 [P] Create terraform/versions.tf with required provider versions (AWS ~> 6.0, Cloudflare ~> 5.0, Terraform >= 1.14)

**Checkpoint**: `terraform init` succeeds in the `terraform/` directory

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core AWS resources that all user stories depend on — variables, data sources, IAM, networking

**CRITICAL**: No user story work can begin until this phase is complete

- [x] T004 Create terraform/variables.tf with all input variables (region, domain, cloudflare_zone_id, cloudflare_account_id, instance_type, tunnel_subdomain, budget_alert_email)
- [x] T005 Add data sources (default VPC, default subnet, Amazon Linux 2023 x86_64 AMI via SSM parameter), IAM role with Bedrock invoke + SSM get-parameter + AmazonSSMManagedInstanceCore policies, and instance profile to terraform/main.tf
- [x] T006 Add security group with zero inbound rules and all-outbound allowed to terraform/main.tf (references default VPC from T005 data source)

**Checkpoint**: `terraform validate` passes. IAM role grants Bedrock invoke + SSM get-parameter + SSM session manager. Security group has no ingress rules.

---

## Phase 3: US3 + US1 + US2 — Deploy Service with Claude Code Access (P2 prerequisite + P1)

**Goal**: Single `terraform apply` provisions the full stack. Claude Code connects through Cloudflare Tunnel and accesses any configured Bedrock model (Anthropic and non-Anthropic).

**Independent Test**: `curl https://llm.matthewdeaves.com/health` returns healthy. Claude Code configured with `ANTHROPIC_BASE_URL` sends a request and receives a streamed response. `/model` lists all configured models with clean aliases.

### Config Files (parallel — different files)

- [x] T007 [P] [US1] [US2] Create config/litellm-config.yaml with all Bedrock model aliases — Anthropic (Opus 4.6, Sonnet 4.6, Haiku 4.5) with Claude Code aliases (claude-sonnet-4-5-20250929 → Sonnet 4.6, claude-opus-4-5-20251101 → Opus 4.6), non-Anthropic (DeepSeek V3.2, Qwen3 Coder 480B, Kimi K2.5, Nova Pro/Lite/Micro) — plus general_settings (master_key from env, database_url from env, max_budget, budget_duration), litellm_settings (drop_params: true, disable admin UI)
- [x] T008 [P] [US3] Create config/litellm.service systemd unit file (ExecStart with litellm proxy, Restart=always, RestartSec=5, env file for DATABASE_URL and LITELLM_MASTER_KEY)
- [x] T009 [P] [US3] Create config/cloudflared.service systemd unit file (ExecStart with tunnel run, Restart=always, RestartSec=5, env file for TUNNEL_TOKEN)
- [x] T010 [P] [US3] Create config/postgresql-tuning.conf with memory settings for 2GB instance (shared_buffers=64MB, work_mem=4MB, effective_cache_size=256MB)

### Bootstrap Script

- [x] T011 [US3] Create scripts/bootstrap.sh — EC2 user data script that: installs PostgreSQL 15 with Restart=always override, creates litellm database and user, applies tuning config, installs LiteLLM (pip3.11, pinned version) and prisma, creates litellm system user with home directory, runs `prisma generate` AS the litellm user (not root — critical for binary path resolution), installs cloudflared, fetches master key and tunnel token from SSM, writes config files and env files, creates swap (512MB), enables and starts all three systemd services

### Terraform Resources

- [x] T012 [US3] Add EC2 instance resource to terraform/main.tf (t3.small, AMI from data source, instance profile, security group, user_data from bootstrap.sh with templatefile, auto-recovery maintenance option, root EBS gp3 volume)
- [x] T013 [P] [US3] Create terraform/tunnel.tf (cloudflare_zero_trust_tunnel_cloudflared resource, tunnel config with ingress rule hostname → localhost:4000, cloudflare_dns_record CNAME to tunnel, aws_ssm_parameter resource to store tunnel token)
- [x] T014 [P] [US3] Create terraform/snapshots.tf (aws_dlm_lifecycle_policy for daily EBS snapshots with 7-day retention, IAM role for DLM)
- [x] T015 [P] [US3] Create terraform/monitoring.tf (Bedrock daily budget alarm with 80%/100% email alerts, CloudWatch alarm for StatusCheckFailed_System with auto-recovery action)
- [x] T016 [US3] Create terraform/outputs.tf (instance_id, tunnel_url, ssm_connect_command)

**Checkpoint**: `terraform plan` shows all resources. After `terraform apply`, health endpoint responds, Claude Code connects with a virtual key, `/model` shows all models, streamed responses work.

---

## Phase 4: US4 — Admin CLI (P2)

**Goal**: `rockport` bash script wraps LiteLLM admin API + AWS CLI for all day-to-day operations.

**Independent Test**: `rockport status` returns health info. `rockport key create test` returns a key. `rockport key list` shows the key with spend. `rockport key info <key>` shows details. `rockport key revoke <key>` revokes it. `rockport spend` shows global spend. `rockport config push` pushes config and restarts.

### Implementation

- [x] T017 [US4] Create scripts/rockport.sh with subcommand structure: `status`, `key create/list/info/revoke`, `models`, `spend`, `config push`, `logs`, `deploy`, `destroy`, `upgrade`
- [x] T018 [US4] Implement SSM master key auto-fetch in scripts/rockport.sh (cache for session, fetch from `/rockport/master-key` via AWS CLI)
- [x] T019 [US4] Implement `rockport deploy` (runs `terraform init -upgrade` + `terraform apply` from terraform/ directory) and `rockport destroy` (confirmation prompt + `terraform destroy`) in scripts/rockport.sh

**Checkpoint**: All `rockport` subcommands work against a deployed instance. Master key is fetched automatically. Output is formatted and readable.

---

## Phase 5: US5 — Admin Upgrades Service (P3)

**Goal**: Config changes and LiteLLM upgrades deploy with a single command and minimal downtime. Existing keys and data survive.

**Independent Test**: Change a model alias in config, run `rockport config push`, verify new model appears in `/v1/models` and existing keys still work.

### Implementation

- [x] T020 [US5] Add LiteLLM version pinning to scripts/bootstrap.sh (pip install litellm==1.82.1)
- [x] T021 [US5] Add `rockport upgrade` subcommand to scripts/rockport.sh that SSMs into the instance and restarts LiteLLM service; add `rockport config push` that base64-encodes local config, writes it to instance via SSM, and restarts LiteLLM

**Checkpoint**: After modifying config/litellm-config.yaml and running `rockport config push`, the new config is active, existing virtual keys still work, downtime is seconds.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: CI validation, smoke tests, client settings, and documentation

- [x] T022 [P] Create .github/workflows/validate.yml — GitHub Actions workflow: on push/PR, run `terraform fmt -check`, `terraform validate`, shellcheck on all scripts
- [x] T023 [P] Create tests/smoke-test.sh — post-deploy checks: health endpoint, auth rejection with invalid key, auth success with valid key, model list contains expected aliases, streamed response works
- [x] T024 [P] Create config/claude-code-settings.json — template settings file for client machines with ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN env vars
- [x] T025 Validate quickstart.md against actual deployment (run through steps, fix discrepancies)

---

## Phase 7: CI/CD Pipeline & Remote State

**Purpose**: Enable automated deployments via GitHub Actions. Migrate Terraform state from local to S3 for multi-machine and CI access.

**Independent Test**: Push a config change to a PR branch → GitHub Actions posts terraform plan as PR comment. Merge to main → terraform apply runs automatically → smoke tests pass.

### S3 Remote State Backend

- [ ] T026 [US5] Create S3 bucket for Terraform state: `aws s3api create-bucket --bucket rockport-tfstate --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2` with versioning enabled (manual one-time step, documented in README)
- [ ] T027 [US5] Create DynamoDB table for state locking: `aws dynamodb create-table --table-name rockport-tfstate-lock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --region eu-west-2` (manual one-time step)
- [ ] T028 [US5] Create terraform/backend.tf with S3 backend configuration (bucket=rockport-tfstate, key=terraform.tfstate, region=eu-west-2, dynamodb_table=rockport-tfstate-lock, encrypt=true)
- [ ] T029 [US5] Run `terraform init -migrate-state` to move local state to S3 (one-time migration)

### GitHub Repository & Secrets

- [ ] T030 [US5] Create private GitHub repo: `gh repo create rockport --private --source=. --push`
- [ ] T031 [US5] Add GitHub secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID, CLOUDFLARE_ACCOUNT_ID via `gh secret set`

### Deploy Workflow

- [ ] T032 [US5] Create .github/workflows/deploy.yml — on PR: terraform plan with PR comment; on merge to main: terraform apply -auto-approve + smoke tests (wait for bootstrap, fetch master key from SSM, run smoke-test.sh)

**Checkpoint**: PR to main triggers plan comment. Merge triggers deploy + smoke tests. State is shared across local machine and CI.

---

## Phase 8: Developer Setup Script

**Purpose**: One-command setup for new machines (Ubuntu/Debian and macOS with Homebrew)

- [x] T033 [P] [US3] Create scripts/setup.sh — cross-platform setup script that installs AWS CLI, Session Manager plugin, Terraform, and GitHub CLI on Ubuntu/Debian (apt/dpkg) or macOS (Homebrew), with idempotent checks and verification output

**Checkpoint**: Running `./scripts/setup.sh` on a fresh Ubuntu or macOS machine installs all prerequisites needed to deploy Rockport.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — `terraform init` must work
- **US3+US1+US2 (Phase 3)**: Depends on Phase 2 — IAM, security group, variables must exist
- **US4 (Phase 4)**: Depends on Phase 3 — needs a deployed instance to talk to
- **US5 (Phase 5)**: Depends on Phase 3 — needs a running instance to upgrade
- **Polish (Phase 6)**: T022 (CI/CD) can start after Phase 1. T023-T025 depend on Phase 3.
- **CI/CD Pipeline (Phase 7)**: Depends on Phase 6 (validate.yml exists). T026-T029 (S3 backend) can start independently. T030-T031 (GitHub repo) depend on having code to push. T032 (deploy workflow) depends on T028 (backend.tf) and T031 (secrets).
- **Setup Script (Phase 8)**: No dependencies — can be done at any time.

### User Story Dependencies

- **US3 (Deploy)**: Foundation for everything. Must complete first.
- **US1 (Claude Code + Anthropic models)**: Delivered alongside US3 — models in config.yaml
- **US2 (Non-Anthropic models)**: Delivered alongside US3 — same config file
- **US4 (Admin CLI)**: Independent of US1/US2. Needs deployed instance.
- **US5 (Upgrades)**: Independent of US4. Needs deployed instance. Phase 7 extends this with CI/CD.

### Within Phase 7

- S3 bucket (T026) and DynamoDB table (T027) are parallel — different AWS services
- backend.tf (T028) depends on T026 + T027 existing
- State migration (T029) depends on T028
- GitHub repo (T030) can run in parallel with T026-T029
- Secrets (T031) depends on T030
- Deploy workflow (T032) depends on T028 + T031

### Parallel Opportunities

```
Phase 2: T005 → T006 (sequential, same file)
Phase 3: T007 (LiteLLM config) ║ T008 (litellm.service) ║ T009 (cloudflared.service) ║ T010 (pg tuning)
Phase 3: T013 (tunnel.tf) ║ T014 (snapshots.tf) ║ T015 (monitoring.tf)
Phase 6: T022 (CI/CD) ║ T023 (smoke test) ║ T024 (settings template)
Phase 7: T026 (S3 bucket) ║ T027 (DynamoDB) ║ T030 (GitHub repo)
Phase 8: T033 (setup script) — independent, any time
```

---

## Implementation Strategy

### MVP First (Phase 1 + 2 + 3)

1. Complete Phase 1: Setup — directory structure, providers, versions, .gitignore
2. Complete Phase 2: Foundational — variables, data sources, IAM, security group
3. Complete Phase 3: US3+US1+US2 — config, bootstrap, all Terraform resources
4. **STOP and VALIDATE**: `terraform apply`, wait for bootstrap, test health + Claude Code + model switching
5. This is a fully working Rockport deployment

### Incremental Delivery

1. Setup + Foundational → `terraform validate` passes
2. Phase 3 → **Working service** — Claude Code connects, all models available (MVP!)
3. Phase 4 → Admin CLI makes management ergonomic
4. Phase 5 → Upgrade workflow validated
5. Phase 6 → Smoke tests, client settings template, CI validation
6. Phase 7 → CI/CD pipeline — push-to-deploy with automated testing
7. Phase 8 → Setup script for new machines

---

## Summary

| Phase | Tasks | Parallel | Description |
|-------|-------|----------|-------------|
| 1: Setup | T001–T003 | 1 | Directory structure, providers, .gitignore |
| 2: Foundational | T004–T006 | 0 | Variables, data sources, IAM, security group |
| 3: US3+US1+US2 | T007–T016 | 7 | Full deployment + all model config |
| 4: US4 | T017–T019 | 0 | Admin CLI |
| 5: US5 | T020–T021 | 0 | Upgrade workflow |
| 6: Polish | T022–T025 | 3 | CI validation, smoke tests, settings, docs |
| 7: CI/CD Pipeline | T026–T032 | 3 | S3 backend, GitHub repo, deploy workflow |
| 8: Setup Script | T033 | 1 | Cross-platform dev setup |
| **Total** | **33** | **15** | |

---

## Notes

- No unit tests — this is an infrastructure project with no custom application code
- Smoke tests (Phase 6) are post-deploy curl checks, not automated test suites
- US1 and US2 are combined with US3 because model config is part of the deployment
- US3 is implemented before US1/US2 despite lower priority because it's the prerequisite
- Phases 1-6 (T001-T025) are COMPLETE — all marked [x]
- Phase 7 (T026-T032) is the next work: S3 backend, GitHub repo, CI/CD deploy workflow
- Phase 8 (T033) is COMPLETE — setup.sh already created
- T026 and T027 are manual AWS CLI commands (documented, not scriptable via Terraform — chicken-and-egg)
- T029 is a one-way migration — must be confirmed before executing
- GitHub Actions deploy workflow requires all secrets (T031) and remote state (T028) before it can run
