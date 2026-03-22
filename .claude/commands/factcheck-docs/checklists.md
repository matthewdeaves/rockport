# Audit Checklists

Use these checklists in Phase 2 to cross-reference every documentation claim against the ground truth from Phase 1.

## README.md

- [ ] Opening description matches actual capabilities
- [ ] "What you get" bullet list — every bullet is true, nothing important is missing
- [ ] Model list matches litellm-config.yaml EXACTLY (model names, no extras, no omissions)
- [ ] Prerequisites section — Marketplace subscription list is accurate
- [ ] CLI commands table — every subcommand exists, descriptions match, no missing commands
- [ ] Configuration variables table — every variable exists in variables.tf, defaults match EXACTLY
- [ ] Image generation model table — dimensions, constraints, defaults all correct per model
- [ ] Image editing section — model names match config, endpoint path is correct, cost table accurate
- [ ] Sidecar endpoint table — only lists endpoints that actually exist in image_api.py
- [ ] Video generation — durations, costs, modes, model comparison table all accurate
- [ ] Security section — every claim matches actual systemd/terraform/WAF config
- [ ] CI/CD section — matches actual workflow files
- [ ] Smoke test description — cost estimate accurate, test count correct
- [ ] Setup section — IAM policy names match actual policies created by init (3 deployer policies, not 1)
- [ ] Setup section — admin vs deployer credential flow accurately described
- [ ] Setup section — profile auto-selection behavior documented
- [ ] No dead links or references to removed features/endpoints

## CLAUDE.md

- [ ] Project Structure tree — run `find` to verify every listed file/directory exists, no missing entries
- [ ] Key Commands table — matches rockport.sh subcommands exactly
- [ ] Important Notes — check EVERY bullet against code:
  - [ ] Ports mentioned match tunnel.tf and systemd units
  - [ ] Region assignments match litellm-config.yaml aws_region_name fields
  - [ ] Model names/IDs match litellm-config.yaml exactly
  - [ ] Endpoint paths match sidecar @router.post decorators
  - [ ] Tunnel routing description matches tunnel.tf ingress rules EXACTLY
  - [ ] WAF description matches waf.tf expression EXACTLY
  - [ ] Memory limits match systemd MemoryMax values
  - [ ] Cost figures match actual Bedrock pricing
  - [ ] Prompt validation rules match prompt_validation.py EXACTLY
  - [ ] Resize modes match image_resize.py EXACTLY
- [ ] Project Structure tree — includes example files (terraform.tfvars.example, .env.example)
- [ ] Project Structure tree — includes all terraform/*.tf files that exist on disk
- [ ] Project Structure tree — includes terraform/lambda/ directory and idle_shutdown.py
- [ ] Project Structure tree — includes .checkov.yaml
- [ ] Active Technologies — no stale feature-branch references (e.g. "(009-complete-image-services)")
- [ ] Active Technologies — version constraints match terraform/versions.tf
- [ ] Recent Changes — is current and accurate
- [ ] Idle shutdown description — thresholds match terraform/lambda/idle_shutdown.py
- [ ] PostgreSQL tuning claims — match config/postgresql-tuning.conf
- [ ] Setup.sh tool list — matches what scripts/setup.sh actually installs
- [ ] No duplicate bullets saying the same thing in different words
- [ ] No bullets that just restate what's obvious from reading the code

## SVG: rockport_architecture_overview.svg

- [ ] Every model box has a model name that exists in litellm-config.yaml
- [ ] No model boxes for models that don't exist in config
- [ ] Region labels match config: check eu-west-2, us-east-1, us-west-2 assignments
- [ ] Service ports (:4000, :4001) match tunnel.tf and systemd
- [ ] cloudflared routing text matches tunnel.tf ingress rules
- [ ] Sidecar box description matches actual sidecar capabilities (video + what image ops?)
- [ ] Memory limits in boxes match systemd MemoryMax
- [ ] AWS services panel matches actual terraform resources (SSM, CloudWatch, DLM, S3, Budgets, Lambda, CloudTrail)
- [ ] CloudTrail box matches cloudtrail.tf configuration (bucket name pattern, lifecycle)

## SVG: rockport_request_dataflow.svg

- [ ] cloudflared routing description matches tunnel.tf ingress (path patterns and port assignments)
- [ ] LiteLLM processing steps match actual auth flow (key format, DB lookup, model restriction, rate limit, budget, routing)
- [ ] Error codes match actual responses (401, 403, 429, 400)
- [ ] Rate limit values match litellm-config.yaml (rpm_limit, tpm_limit)
- [ ] Budget values match litellm-config.yaml (max_budget, default budget)
- [ ] Video sidecar flow matches video_api.py (auth, validation, budget, Bedrock call, concurrent limit)
