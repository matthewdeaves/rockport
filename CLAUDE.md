# Rockport

LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing Claude Code to Bedrock models — chat, image generation, and video generation.

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
terraform/.build/       # Lambda zip artifacts (gitignored)
terraform/s3.tf         # S3 bucket for video output (us-east-1)
config/                 # LiteLLM config, systemd units, PostgreSQL tuning
  litellm-config.yaml   #   Model definitions, budget, rate limits
  litellm.service       #   Systemd unit for LiteLLM proxy
  cloudflared.service   #   Systemd unit for Cloudflare Tunnel
  rockport-video.service #  Systemd unit for video generation sidecar
  postgresql-tuning.conf #  PostgreSQL memory tuning for t3.small
sidecar/                # Video generation sidecar (FastAPI on port 4001)
  video_api.py          #   API endpoints, auth, validation, Bedrock client
  db.py                 #   PostgreSQL job tracking, spend logging
scripts/bootstrap.sh    # EC2 user_data — installs PostgreSQL, LiteLLM, cloudflared, video sidecar
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
./scripts/rockport.sh monitor       # Key status + recent requests [--live] [--interval N] [--count N]
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
- Image-to-image: use `/v1/images/generations` with `textToImageParams.conditionImage` (Nova Canvas) — NOT `/v1/images/edits` which LiteLLM 1.82.2 doesn't support for Bedrock models
- Cloudflare blocks requests with Python's default `Python-urllib` user-agent (403) — OpenAI SDK and curl work fine
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks NetworkIn metrics)
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
- The admin CLI requires `aws`, `terraform`, and `jq` — run `./scripts/setup.sh` to install all tools
- Three SSM parameters are managed: `/rockport/master-key` (by init), `/rockport/tunnel-token` (by Terraform), `/rockport/db-password` (by bootstrap)
- CI/CD uses GitHub OIDC for AWS authentication — set the `AWS_ROLE_ARN` secret in GitHub to the IAM role ARN
- The LiteLLM admin UI is intentionally disabled (`disable_admin_ui: true`) — all admin is via the CLI
- Swagger/ReDoc docs disabled via `NO_DOCS=True` / `NO_REDOC=True` in the LiteLLM env file
- Cloudflare WAF allowlist (`terraform/waf.tf`) blocks all paths except those needed by Claude Code, image generation (`/v1/images/generations`), video generation (`/v1/videos/*`), and the admin CLI
- `setup-claude` creates keys restricted to Anthropic models only; `key create` without `--claude-only` grants access to all models including image generation
- Stability AI image models (SD3.5 Large) need a one-time Marketplace subscription — invoke once in the Bedrock playground to activate
- `deploy` auto-creates the SSM master key if missing, so `init` is not a strict prerequisite
- The Cloudflare API token (in `terraform/.env`, gitignored) needs Zone WAF Edit permission for the WAF rule
- Deployer IAM is split into 3 policies under `terraform/deployer-policies/` (compute, iam-ssm, monitoring-storage) to stay under the 6144-byte per-policy limit while keeping all actions explicit (no wildcards). EC2/SSM mutating actions scoped to `aws:ResourceTag/Project=rockport`
- Admin IAM policy (`terraform/rockport-admin-policy.json`) is a one-time bootstrap: must be created and attached to the admin user via the AWS console (root account) before first `init`. After that, `init` self-manages it.
- HSTS and "Always Use HTTPS" are enabled in Cloudflare (not managed by Terraform)
- Video generation: Nova Reel v1.1 via sidecar FastAPI service on port 4001, us-east-1 only, fixed 1280x720 24fps MP4, duration must be multiple of 6 (6-120s), $0.08/second
- Video sidecar authenticates via LiteLLM's `/key/info` endpoint; writes spend to `LiteLLM_SpendLogs` + `LiteLLM_VerificationToken` for unified tracking
- Video output stored in S3 bucket `rockport-video-{account}-us-east-1` with 7-day lifecycle; presigned URLs expire after 1 hour
- Cloudflare Tunnel routes `/v1/videos/*` to `http://localhost:4001` — managed in `terraform/tunnel.tf`
- Video sidecar MemoryMax is 256MB; LiteLLM reduced to 1280MB to fit on t3.small (2GB + 512MB swap)
- Single-shot (one prompt, 6-120s) and multi-shot (2-20 per-shot prompts, 6s each) modes supported
- Image-to-video: single-shot with image is fixed at 6s duration; multi-shot uses `MULTI_SHOT_MANUAL` taskType with `multiShotManualParams.shots`
- Video image requirements: exactly 1280x720, PNG or JPEG, no transparent pixels (opaque alpha channels are automatically stripped), max 10MB, submitted as data URIs
- Bedrock image format: `{format: "png"|"jpeg", source: {bytes: "<raw-base64>"}}` — data URI prefix must be stripped
- Per-key concurrent job limit defaults to 3 (configurable via `VIDEO_MAX_CONCURRENT_JOBS` env var)
- Video sidecar accepted risks: (1) TOCTOU race on concurrent job count and budget — low risk at expected scale (~10-20 jobs/day), would need advisory locks to fully fix; (2) `ListAsyncInvokes` IAM may need `Resource: "*"` — health check will fail if so, fix on first deploy
## Active Technologies
- Terraform (AWS provider, Cloudflare provider) — all infrastructure
- Python 3.11 + FastAPI, uvicorn, boto3, Pillow, psycopg2, pydantic — video sidecar
- PostgreSQL 15 — LiteLLM keys/spend + video job tracking (`rockport_video_jobs` table)
- S3 — Terraform state (eu-west-2) + video output (us-east-1, 7-day lifecycle)
- Bash — admin CLI, bootstrap, smoke tests
