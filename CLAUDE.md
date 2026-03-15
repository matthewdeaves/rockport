# Rockport

LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing Claude Code to Bedrock models.

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
terraform/.build/       # Lambda zip artifacts (gitignored)
config/                 # LiteLLM config, systemd units, PostgreSQL tuning
  litellm-config.yaml   #   Model definitions, budget, rate limits
  litellm.service       #   Systemd unit for LiteLLM proxy
  cloudflared.service   #   Systemd unit for Cloudflare Tunnel
  postgresql-tuning.conf #  PostgreSQL memory tuning for t3.small
scripts/bootstrap.sh    # EC2 user_data — installs PostgreSQL, LiteLLM, cloudflared
scripts/rockport.sh     # Admin CLI (init, keys, status, spend, logs, deploy, start/stop)
tests/smoke-test.sh     # Post-deploy verification
.github/workflows/      # CI/CD — validate (fmt, lint, security scan) + deploy (plan/apply/smoke)
.checkov.yaml           # Checkov skip list with justifications
```

## Key Commands

```bash
./scripts/rockport.sh init          # Interactive setup — creates tfvars + SSM master key
./scripts/rockport.sh deploy        # terraform init + apply
./scripts/rockport.sh destroy       # terraform destroy (confirms, cleans up SSM params)
./scripts/rockport.sh status        # Health + model list
./scripts/rockport.sh start         # Start a stopped instance
./scripts/rockport.sh stop          # Stop the instance
./scripts/rockport.sh upgrade       # Restart LiteLLM via SSM
./scripts/rockport.sh key create X  # Create virtual API key [--budget N] [--claude-only]
./scripts/rockport.sh key list      # List keys
./scripts/rockport.sh key info <k>  # Key details + spend
./scripts/rockport.sh key revoke <k># Revoke key
./scripts/rockport.sh spend         # Global spend summary
./scripts/rockport.sh spend keys    # Spend breakdown by key
./scripts/rockport.sh config push   # Push config to instance + restart
./scripts/rockport.sh logs          # Stream LiteLLM journal
./scripts/rockport.sh setup-claude  # Create Anthropic-only key + show Claude Code config
```

## Important Notes

- `prisma generate` MUST run as the `litellm` user (not root) — it hardcodes `$HOME/.cache/` paths into the generated client
- The `litellm` user's home is `/var/lib/litellm` (not `/home/litellm`) so prisma cache works with `ProtectHome=yes`
- Terraform `user_data` only runs on first boot; use `config push` or `upgrade` for runtime changes
- Claude Code sends old model IDs (e.g. `claude-sonnet-4-5-20250929`); aliases in litellm-config.yaml map these to latest 4.6 Bedrock models
- Bedrock inference profiles need `eu.` prefix for cross-region models; IAM policy must cover ALL EU regions (the inference profile can route to any) + us-west-2 + us-east-1 for image generation
- The EC2 instance needs a public IP for outbound internet (SSM, Bedrock, pip) — the default VPC has no NAT gateway. The SG has zero inbound rules so the public IP is not directly reachable
- Image generation models: Nova Canvas (us-east-1), Titan Image v2 (us-west-2), SD3.5 Large (us-west-2) — routed via per-model `aws_region_name` in litellm-config.yaml
- Image dimensions via OpenAI `size` param: Nova Canvas requires divisible by 64 (320–2048, max 4.1MP); Titan v2 uses preset sizes (256–1408); SD3.5 Large ignores `size` (fixed 1024x1024, returns JPEG not PNG)
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks NetworkIn metrics)
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
- The admin CLI requires `aws`, `terraform`, and `jq` — run `./scripts/setup.sh` to install all tools
- Three SSM parameters are managed: `/rockport/master-key` (by init), `/rockport/tunnel-token` (by Terraform), `/rockport/db-password` (by bootstrap)
- CI/CD uses GitHub OIDC for AWS authentication — set the `AWS_ROLE_ARN` secret in GitHub to the IAM role ARN
- The LiteLLM admin UI is intentionally disabled (`disable_admin_ui: true`) — all admin is via the CLI
- Swagger/ReDoc docs disabled via `NO_DOCS=True` / `NO_REDOC=True` in the LiteLLM env file
- Cloudflare WAF allowlist (`terraform/waf.tf`) blocks all paths except those needed by Claude Code, image generation (`/v1/images/generations`), and the admin CLI
- `setup-claude` creates keys restricted to Anthropic models only; `key create` without `--claude-only` grants access to all models including image generation
- Stability AI image models (SD3.5 Large) need a one-time Marketplace subscription — invoke once in the Bedrock playground to activate
- `deploy` auto-creates the SSM master key if missing, so `init` is not a strict prerequisite
- The Cloudflare API token (in `terraform/.env`, gitignored) needs Zone WAF Edit permission for the WAF rule
- Deployer IAM policy (`terraform/rockport-deployer-policy.json`) scopes EC2/SSM mutating actions to `aws:ResourceTag/Project=rockport` — the SG and instance must have this tag
- HSTS and "Always Use HTTPS" are enabled in Cloudflare (not managed by Terraform)
