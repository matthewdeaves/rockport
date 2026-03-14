# Rockport

LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing Claude Code to Bedrock models.

## Project Structure

```
terraform/          # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
config/             # LiteLLM config, systemd units (settings files generated per key)
scripts/bootstrap.sh  # EC2 user_data — installs PostgreSQL, LiteLLM, cloudflared
scripts/rockport.sh   # Admin CLI (init, keys, status, spend, logs, deploy, start/stop)
tests/smoke-test.sh   # Post-deploy verification
```

## Key Commands

```bash
./scripts/rockport.sh init          # Interactive setup — creates tfvars + SSM master key
./scripts/rockport.sh deploy        # terraform init + apply
./scripts/rockport.sh destroy       # terraform destroy (confirms)
./scripts/rockport.sh status        # Health + model list
./scripts/rockport.sh start         # Start a stopped instance
./scripts/rockport.sh stop          # Stop the instance
./scripts/rockport.sh upgrade       # Restart LiteLLM via SSM
./scripts/rockport.sh key create X  # Create virtual API key [--budget N]
./scripts/rockport.sh key list      # List keys
./scripts/rockport.sh key info <k>  # Key details + spend
./scripts/rockport.sh key revoke <k># Revoke key
./scripts/rockport.sh spend         # Global spend summary
./scripts/rockport.sh spend keys    # Spend breakdown by key
./scripts/rockport.sh config push   # Push config to instance + restart
./scripts/rockport.sh logs          # Stream LiteLLM journal
./scripts/rockport.sh setup-claude  # Create key + show Claude Code config
```

## Important Notes

- `prisma generate` MUST run as the `litellm` user (not root) — it hardcodes `$HOME/.cache/` paths
- Terraform `user_data` only runs on first boot; use `config push` or `upgrade` for runtime changes
- Claude Code sends old model IDs (e.g. `claude-sonnet-4-5-20250929`); aliases in litellm-config.yaml map these to latest 4.6 Bedrock models
- Bedrock inference profiles need `eu.` prefix for cross-region models in eu-west-2
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks NetworkIn metrics)
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
