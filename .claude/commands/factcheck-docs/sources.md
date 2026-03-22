# Source-of-Truth Files

Read ALL of the following files in Phase 1. Do not skip any.

## 1. LiteLLM config — `config/litellm-config.yaml`

- Extract every model entry: `model_name`, `litellm_params.model` (full Bedrock ID including any `us.` prefix), `aws_region_name`, `model_info.mode`, any extra fields like `disable_background_health_check`
- Extract `general_settings` (master_key source, database_url, max_budget, budget_duration)
- Extract `litellm_settings` (drop_params, disable_admin_ui, etc.)
- Extract `default_key_generate_params` (rpm_limit, tpm_limit)

## 2. Terraform infrastructure

Read ALL of these:
- `terraform/tunnel.tf` — extract the EXACT ingress rules list (path, service, order)
- `terraform/waf.tf` — extract the EXACT WAF expression (every `not starts_with` line and exact match)
- `terraform/access.tf` — Cloudflare Access configuration
- `terraform/variables.tf` — every variable with its default value and description
- `terraform/main.tf` — instance type, AMI, user_data reference, key resources
- `terraform/s3.tf` — bucket names, regions, lifecycle rules
- `terraform/cloudtrail.tf` — CloudTrail trail and S3 bucket configuration
- `terraform/providers.tf` — provider configuration (AWS, Cloudflare)
- `terraform/versions.tf` — Terraform and provider version constraints
- `terraform/deployer-policies/*.json` — IAM policy structure

## 3. Sidecar code

Read these files:
- `sidecar/image_api.py` — extract every `@router.post` path, every Pydantic model class, every Bedrock model ID and region used, every helper function that still exists
- `sidecar/video_api.py` — extract every endpoint, model support, validation rules, concurrent job limits
- `sidecar/prompt_validation.py` — extract exact validation rules (negation words, camera keywords, min length)
- `sidecar/image_resize.py` — extract resize modes and constraints
- `sidecar/db.py` — extract what tables are used
- `sidecar/requirements.txt` — list of dependencies

## 4. Admin CLI — `scripts/rockport.sh`

- Extract ALL subcommands by reading the usage/help section at the bottom
- Extract the `CLAUDE_MODELS` variable (exact model list for --claude-only)
- Extract any hardcoded values (ports, paths, model names, version strings)
- Check the health check logic — what patterns are matched, what gets probed vs skipped

## 5. Smoke tests — `tests/smoke-test.sh`

- Extract every test number, name, what it tests, and expected HTTP codes
- Count total tests

## 6. Bootstrap — `scripts/bootstrap.sh`

- Extract services installed, system users created, ports bound, systemd units deployed
- Extract LiteLLM version, Python version

## 7. Systemd units and config — `config/`

Read ALL service files and config:
- `config/*.service` — extract service name, user, MemoryMax, security hardening flags, ExecStart commands and ports
- `config/postgresql-tuning.conf` — PostgreSQL memory tuning parameters

## 8. CI/CD — `.github/workflows/*.yml`

- Extract workflow names, triggers, steps

## 9. IAM policies

- `terraform/deployer-policies/*.json` and `terraform/rockport-admin-policy.json`
- Extract key permissions and scoping

## 10. Example files and gitignore

- `terraform/terraform.tfvars.example` — every variable in `variables.tf` must be present, defaults must match exactly, required vs optional must be correct
- `terraform/.env.example` — must exist and document the Cloudflare API token
- `.gitignore` — must exclude `.env*` and `*.tfvars` but include `!.env.example`, `!*.env.example`, `!*.tfvars.example`

## 11. Additional Terraform files

- `terraform/idle.tf` — Lambda, EventBridge, CloudWatch alarm resources
- `terraform/lambda/idle_shutdown.py` — Lambda function source (idle shutdown logic, thresholds)
- `terraform/monitoring.tf` — budget alarms, SNS, auto-recovery
- `terraform/outputs.tf` — all output names and sensitivity markers
- `terraform/snapshots.tf` — DLM lifecycle policy

## 12. Init/deploy flow — `scripts/rockport.sh`

- Extract the admin vs deployer credential flow (auto-profile selection, init override)
- Extract what `cmd_init` creates (IAM policies, deployer user, access keys, CLI profile, master key, state bucket)
- Extract what `cmd_destroy` cleans up (and what it doesn't — IAM users/policies, CLI profile, orphaned log groups)

## 13. Developer setup — `scripts/setup.sh`

- Extract tools installed and their purposes
- Cross-reference with CLAUDE.md's claim about what `setup.sh` installs

## 14. Security scanning — `.checkov.yaml`

- Extract skip rules and their justifications
- Verify justifications are still valid
