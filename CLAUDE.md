# Rockport

OpenAI-compatible LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing any application to Bedrock models — chat, image generation, and video generation. Built for Claude Code but works with any OpenAI SDK client.

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
terraform/.build/       # Lambda zip artifacts (gitignored)
terraform/lambda/       # Lambda function source code (idle_shutdown.py)
terraform/moved.tf      # Moved blocks template for safe resource renames
terraform/access.tf     # Cloudflare Access application + service token (edge pre-auth)
terraform/s3.tf         # S3 buckets for video output (us-east-1 + us-west-2)
config/                 # LiteLLM config, systemd units, PostgreSQL tuning
  litellm-config.yaml   #   Model definitions, budget, rate limits
  litellm.service       #   Systemd unit for LiteLLM proxy
  cloudflared.service   #   Systemd unit for Cloudflare Tunnel
  rockport-video.service #  Systemd unit for video generation sidecar
  postgresql-tuning.conf #  PostgreSQL memory tuning for t3.small
sidecar/                # Video + image services sidecar (FastAPI on port 4001)
  video_api.py          #   Video endpoints, auth, validation, Bedrock client
  image_api.py          #   Image service endpoints (variations, outpaint, Stability AI tools)
  image_resize.py       #   Auto-resize for Nova Reel (scale, crop, fit to 1280x720)
  prompt_validation.py  #   Nova Reel prompt validation (negation, camera placement, length)
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
./scripts/rockport.sh spend         # Combined infra + model usage summary
./scripts/rockport.sh spend keys    # Spend breakdown by key
./scripts/rockport.sh spend models  # Spend breakdown by model
./scripts/rockport.sh spend daily [N] # Daily spend for last N days (default 30)
./scripts/rockport.sh spend today   # Today's spend by key and model
./scripts/rockport.sh spend infra [N] # AWS infra costs for last N months (default 3)
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
- Image generation models: Nova Canvas (us-east-1), Titan Image v2 (us-west-2), SD3.5 Large (us-west-2), Stable Image Ultra v1.1 (us-west-2), Stable Image Core v1.1 (us-west-2) — routed via per-model `aws_region_name` in litellm-config.yaml
- Image dimensions via OpenAI `size` param: Nova Canvas requires divisible by 16 (320–4096); Titan v2 uses preset sizes (256–1408); SD3.5 Large ignores `size` (fixed 1024x1024, returns JPEG not PNG)
- Image-to-image: use `/v1/images/generations` with `textToImageParams.conditionImage` (Nova Canvas) — NOT `/v1/images/edits` which LiteLLM 1.82.3 doesn't support for Bedrock models
- Cloudflare blocks requests with Python's default `Python-urllib` user-agent (403) — OpenAI SDK and curl work fine
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks both NetworkIn and CPUUtilization — instance is only stopped when both are below threshold). A CloudWatch alarm fires if the idle-stop Lambda itself fails consecutively
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
- The admin CLI requires `aws`, `terraform`, and `jq` — run `./scripts/setup.sh` to install all tools (also installs shellcheck, trivy, checkov, gitleaks)
- Three SSM parameters are managed: `/rockport/master-key` (by init), `/rockport/tunnel-token` (by Terraform), `/rockport/db-password` (by bootstrap)
- CI/CD uses GitHub OIDC for AWS authentication — set the `AWS_ROLE_ARN` secret in GitHub to the IAM role ARN
- The LiteLLM admin UI is intentionally disabled (`disable_admin_ui: true`) — all admin is via the CLI
- Swagger/ReDoc docs disabled via `NO_DOCS=True` / `NO_REDOC=True` in the LiteLLM env file
- Cloudflare Access (`terraform/access.tf`) requires a service token for all requests — `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers must be present or Cloudflare returns 403 before traffic reaches the tunnel. Token values are Terraform outputs (sensitive). To rotate: create a new service token in Terraform, update all clients, then remove the old one
- Cloudflare WAF allowlist (`terraform/waf.tf`) blocks all paths except those needed by Claude Code, image generation (`/v1/images/generations`, `/v1/images/*`), video generation (`/v1/videos/*`), and the admin CLI
- `setup-claude` creates keys restricted to Anthropic models only; `key create` without `--claude-only` grants access to all models including image generation
- Stability AI image models (SD3.5 Large) need a one-time Marketplace subscription — invoke once in the Bedrock playground to activate
- `deploy` auto-creates the SSM master key if missing, so `init` is not a strict prerequisite
- The Cloudflare API token (in `terraform/.env`, gitignored) needs Zone WAF Edit + Access Edit permissions for the WAF rule and Cloudflare Access application
- Deployer IAM is split into 3 policies under `terraform/deployer-policies/` (compute, iam-ssm, monitoring-storage) to stay under the 6144-byte per-policy limit while keeping all actions explicit (no wildcards). EC2/SSM mutating actions scoped to `aws:ResourceTag/Project=rockport`. An explicit Deny in iam-ssm.json blocks `AttachRolePolicy`/`DetachRolePolicy` for any policy ARN not matching `Rockport*` or `rockport*`, preventing privilege escalation via the deployer role
- Admin IAM policy (`terraform/rockport-admin-policy.json`) is a one-time bootstrap: must be created and attached to the admin user via the AWS console (root account) before first `init`. After that, `init` self-manages it.
- HSTS and "Always Use HTTPS" are enabled in Cloudflare (not managed by Terraform)
- Video generation: multi-model sidecar on port 4001 supporting Nova Reel v1.1 (us-east-1, 1280x720, 6-120s, $0.08/s) and Luma Ray2 (us-west-2, 540p/720p, 5s/9s, $0.75-1.50/s). Model selected via `model` field, defaults to `nova-reel`
- Video sidecar authenticates via LiteLLM's `/key/info` endpoint; writes spend to `LiteLLM_SpendLogs` + `LiteLLM_VerificationToken` for unified tracking
- Video output stored in per-region S3 buckets (`rockport-video-{account}-us-east-1` for Nova Reel, `rockport-video-{account}-us-west-2` for Ray2) with 7-day lifecycle; presigned URLs expire after 1 hour. Bedrock async invoke requires same-region S3 bucket
- Cloudflare Tunnel routes `/v1/videos/*` and `/v1/images/*` (except `/v1/images/generations`) to `http://localhost:4001`; all else to `:4000` — managed in `terraform/tunnel.tf`
- Video sidecar MemoryMax is 256MB; LiteLLM reduced to 1280MB to fit on t3.small (2GB + 512MB swap)
- Single-shot (one prompt, 6-120s), multi-shot (2-20 per-shot prompts, 6s each), and multi-shot-automated (single prompt, 12-120s, model determines shot breakdown) modes supported
- Image-to-video: Nova Reel single-shot with image is fixed at 6 seconds (Bedrock TEXT_VIDEO constraint); multi-shot uses `MULTI_SHOT_MANUAL` taskType with `multiShotManualParams.shots`
- Nova Reel image requirements: exactly 1280x720, PNG or JPEG, no transparent pixels (opaque alpha channels are automatically stripped), max 10MB, submitted as data URIs. Bedrock format: `{format: "png"|"jpeg", source: {bytes: "<raw-base64>"}}`
- Ray2 image requirements: 512x512 to 4096x4096, PNG or JPEG, max 25MB, data URIs. Bedrock format: `keyframes.frame0/frame1` with `{type: "image", source: {type: "base64", media_type, data}}`. Supports start + optional end frame
- Ray2 extra params: `aspect_ratio` (7 options), `resolution` (540p/720p), `loop` (bool). No multi-shot, no seed. Requires Marketplace subscription
- Luma Ray2 Marketplace subscription must be activated manually before first use (same pattern as SD3.5 Large)
- Per-key concurrent job limit defaults to 3 (configurable via `VIDEO_MAX_CONCURRENT_JOBS` env var)
- Video sidecar concurrent job limit enforced atomically via `pg_advisory_xact_lock(hashtext(api_key_hash))` — count and insert happen in a single transaction, preventing TOCTOU races. Different API keys use different lock IDs so they don't block each other
- Bootstrap runs `prisma migrate deploy` before LiteLLM starts — avoids slow per-migration baseline resolve (~10s x 108 migrations) on first boot. Full bootstrap completes in ~3 minutes
- Image service endpoints on sidecar (:4001): `/v1/images/variations`, `/v1/images/background-removal`, `/v1/images/outpaint` (Nova Canvas); `/v1/images/structure`, `/v1/images/sketch`, `/v1/images/style-transfer`, `/v1/images/remove-background`, `/v1/images/search-replace`, `/v1/images/upscale`, `/v1/images/style-guide`, `/v1/images/inpaint`, `/v1/images/erase`, `/v1/images/creative-upscale`, `/v1/images/fast-upscale`, `/v1/images/search-recolor`, `/v1/images/stability-outpaint` (Stability AI). All enforce auth, budgets, and block --claude-only keys
- New Stability AI endpoint costs: inpaint ($0.04), erase ($0.04), creative-upscale ($0.06), fast-upscale ($0.04), search-recolor ($0.04), stability-outpaint ($0.04)
- Stable Image Ultra ($0.14/image) and Core ($0.04/image) available via `/v1/images/generations` with model names `stable-image-ultra` and `stable-image-core`
- Nova Canvas style presets supported via `textToImageParams.style` field: 3D_ANIMATED_FAMILY_FILM, DESIGN_SKETCH, FLAT_VECTOR_ILLUSTRATION, GRAPHIC_NOVEL_ILLUSTRATION, MAXIMALISM, MIDCENTURY_RETRO, PHOTOREALISM, SOFT_DIGITAL_PAINTING
- Nova Reel auto-resize: images not exactly 1280x720 are automatically resized. Five modes: `scale` (default), `crop-center`, `crop-top`, `crop-bottom`, `fit` (with pad). Controlled via `resize_mode` and `pad_color` params
- Nova Reel prompt validation: rejects prompts with negation words (model interprets them positively), camera keywords before the final clause, and prompts shorter than 50 characters
- `rockport.sh status` shows instance memory/CPU/uptime stats via SSM in addition to health checks
## Active Technologies
- Terraform (AWS provider, Cloudflare provider) — all infrastructure
- Python 3.11 + FastAPI, uvicorn, boto3, Pillow, psycopg2, pydantic, httpx — sidecar (video + image services, multi-region clients for us-east-1 + us-west-2)
- PostgreSQL 15 — LiteLLM keys/spend + video job tracking (`rockport_video_jobs` table with `model` column)
- S3 — Terraform state (eu-west-2) + video output (us-east-1 for Nova Reel, us-west-2 for Ray2, both 7-day lifecycle)
- Bash — admin CLI, bootstrap, smoke tests
- Python 3.11 (sidecar), YAML (LiteLLM config), Bash (smoke tests), HCL (Terraform) + FastAPI, uvicorn, boto3, Pillow, pydantic, psycopg2 (all already installed) (009-complete-image-services)
- PostgreSQL 15 (spend logging to existing LiteLLM_SpendLogs table) (009-complete-image-services)

## Recent Changes
- 009-complete-image-services: Added Python 3.11 (sidecar), YAML (LiteLLM config), Bash (smoke tests), HCL (Terraform) + FastAPI, uvicorn, boto3, Pillow, pydantic, psycopg2 (all already installed)
