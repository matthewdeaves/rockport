# Rockport

OpenAI-compatible LiteLLM proxy on EC2 that routes any application to Bedrock models — chat, image generation, and video generation — through a single HTTPS endpoint. Built for Claude Code but works with any OpenAI SDK client. Cloudflare Tunnel provides ingress with zero inbound ports; Terraform manages everything.

## Architecture

[![Architecture Overview](docs/rockport_architecture_overview.svg?v=2)](https://raw.githubusercontent.com/matthewdeaves/rockport/main/docs/rockport_architecture_overview.svg)

[![Request Data Flow](docs/rockport_request_dataflow.svg?v=2)](https://raw.githubusercontent.com/matthewdeaves/rockport/main/docs/rockport_request_dataflow.svg)

## What you get

- Claude Code connects via `ANTHROPIC_BASE_URL` to your own proxy
- Anthropic (Opus 5, Sonnet 5, Opus 4.8/4.7/4.6, Sonnet 4.6, Haiku 4.5), DeepSeek V3.2, Qwen3 Coder 480B, Kimi K2.5, Nova Pro/Lite/Micro, Nova 2 Lite, Llama 4 Scout/Maverick, Mistral Large 3, Ministral 8B, GPT-OSS 120B/20B on Bedrock
- Image generation via OpenAI-compatible `/v1/images/generations` (Stable Image Core, Stable Image Ultra, SD3.5 Large)
- Image editing via `/v1/images/edits` — 13 Stability AI operations (structure, sketch, style transfer, upscale, inpaint, erase, search & recolor, and more) via LiteLLM native
- Palette & style control: style reference (`--sref`-style) via Stability Style Guide, hex colour palettes via the sidecar `/v1/images/palette` endpoint
- Video generation via `/v1/videos/generations` (Luma Ray2 — async jobs with presigned S3 URLs)
- Virtual API keys with per-key budgets, rate limits, and model restrictions
- Zero inbound security group rules — all traffic flows through Cloudflare Tunnel
- Daily EBS snapshots with 7-day retention
- Auto-recovery on system failure
- Auto-stop after 30 minutes of inactivity (checks both network and CPU; 10-minute grace period after boot)
- Daily Bedrock budget alerts + monthly overall AWS budget alerts
- `rockport` CLI for key management, logs, deploys, start/stop

## Prerequisites

Before you start, you need:

1. **An AWS account** with an IAM user that has admin access (or root credentials for first-time setup)
2. **A Cloudflare account** with a domain — you'll create an API token and a tunnel
3. **Bedrock model access** — see "Bedrock model access" below

### Cloudflare API token

Create a token at https://dash.cloudflare.com/profile/api-tokens with these permissions:
- **Zone / DNS / Edit**
- **Zone / Zone WAF / Edit**
- **Account / Cloudflare Tunnel / Edit**
- **Account / Zero Trust / Edit** (for Cloudflare Access service token authentication)

You'll also need your Cloudflare **Zone ID** and **Account ID** (found on the domain overview page).

### Bedrock model access

Serverless foundation models auto-enable on first invocation. For Stability AI image models (SD3.5 Large, Stable Image Ultra, Stable Image Core, and all Stability AI image edit models like inpaint, erase, upscale, etc.) and Luma Ray2, open the model in the Bedrock playground once to trigger the Marketplace subscription. Chat models (Claude, Nova, etc.) work immediately.

## Setup

### 1. Install tools

```bash
./scripts/setup.sh
```

This installs AWS CLI v2, Session Manager plugin, Terraform, GitHub CLI, ShellCheck, Trivy, Checkov, Gitleaks, and pip-audit. Or install them manually.

### 2. Configure AWS credentials

You need working AWS credentials before running `init`. How you do this depends on your situation:

**Fresh AWS account (no IAM users yet):**

Use your root account access keys temporarily. Go to AWS Console > IAM > Security credentials > Create access key, then:

```bash
aws configure
# AWS Access Key ID: <root-access-key>
# AWS Secret Access Key: <root-secret-key>
# Default region name: eu-west-2
```

The `init` command will create a dedicated `rockport-deployer` IAM user and the scoped IAM policies; the first `deploy` then creates three MFA-gated operator roles (readonly / runtime-ops / deploy) via Terraform. After init completes, enrol an MFA device on `rockport-deployer` (see "MFA Enrolment" below) and the CLI handles role selection per subcommand via `SUBCOMMAND_ROLE`.

**Existing AWS account with an admin IAM user:**

```bash
aws configure
# AWS Access Key ID: <your-admin-key>
# AWS Secret Access Key: <your-admin-secret>
# Default region name: eu-west-2
```

Again, `init` will create the `rockport-deployer` user and `rockport` CLI profile. Your admin user only needs to be used for this one-time setup.

### 3. Initialize

```bash
./scripts/rockport.sh init
```

This is an interactive setup that:
- Prompts for your AWS region, domain, Cloudflare IDs, and budget alert email
- Creates 7 scoped IAM policies: 3 deployer (compute, IAM/SSM, monitoring/storage) + 2 operator (readonly, runtime-ops) + 1 AssumeRole policy
- Creates a `rockport-deployer` IAM user with access keys
- Generates a master API key and stores it in SSM Parameter Store
- Creates an S3 bucket for Terraform state

If you already have a `terraform.tfvars` from a previous setup, init will ask whether to keep it and just ensure the IAM policies, master key, and state bucket exist.

### 4. MFA Enrolment

Before any subsequent CLI command, enrol a TOTP MFA device on `rockport-deployer`:

1. AWS console → IAM → Users → `rockport-deployer` → Security credentials → Multi-factor authentication → Assign MFA device.
2. Choose Authenticator app, name it (e.g. `rockport-deployer-laptop`), scan the QR code, enter two consecutive codes.
3. Copy the device ARN.
4. Add it to `terraform/.env` (gitignored):

   ```bash
   echo 'export MFA_SERIAL_NUMBER="arn:aws:iam::<account>:mfa/rockport-deployer-laptop"' >> terraform/.env
   ```

Now `./scripts/rockport.sh auth --role readonly` will prompt for a 6-digit TOTP code and cache a 1-hour session. Subsequent diagnostic commands reuse the cached session; mutating commands (config push, deploy) prompt for MFA again because they use a different role.

> **Bootstrap escape hatch:** for the very first `rockport.sh deploy` on a fresh account where the operator roles don't exist yet, prefix the command with `ROCKPORT_AUTH_DISABLED=1` to skip role assumption and use admin credentials directly.

### 5. Deploy

```bash
ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh deploy   # first deploy, before operator roles exist
./scripts/rockport.sh deploy                            # subsequent deploys, prompts for MFA on the deploy role
```

Takes ~2 minutes for Terraform, then ~3 minutes for the EC2 instance to bootstrap (installs PostgreSQL, LiteLLM, cloudflared).

### 6. Verify and configure Claude Code

```bash
# Wait for bootstrap (~3 min), then check health:
./scripts/rockport.sh status

# Generate a key and get Claude Code config:
./scripts/rockport.sh setup-claude

# Copy the generated settings file:
cp config/claude-code-settings-<key-name>.json ~/.claude/settings.json
```

Launch Claude Code. The generated settings default to `claude-sonnet-5`; pick Opus per session with `/model`.

## Admin CLI

```bash
./scripts/rockport.sh init                          # Interactive setup
./scripts/rockport.sh deploy                        # Run terraform apply [--admin when an operator boundary policy changes]
./scripts/rockport.sh status                        # Health check + model list
./scripts/rockport.sh models                        # List available models
./scripts/rockport.sh key create <name> [--budget N] [--claude-only] # Create API key
./scripts/rockport.sh key list                      # List all keys with spend
./scripts/rockport.sh key info <key>                # Key details + spend
./scripts/rockport.sh key revoke <key>              # Revoke a key
./scripts/rockport.sh spend                         # Combined infra + model usage summary
./scripts/rockport.sh spend keys                    # Spend breakdown by key
./scripts/rockport.sh spend models                  # Spend breakdown by model
./scripts/rockport.sh spend daily [N]               # Daily spend for last N days (default 30)
./scripts/rockport.sh spend today                   # Today's spend by key and model
./scripts/rockport.sh spend infra [N]               # AWS infrastructure costs for last N months (default 3)
./scripts/rockport.sh monitor                       # Key status + recent requests
./scripts/rockport.sh monitor --live                # Live dashboard (auto-refresh)
./scripts/rockport.sh config push                   # Push config to instance + restart
./scripts/rockport.sh logs                          # Stream LiteLLM logs
./scripts/rockport.sh upgrade                       # Restart LiteLLM + video sidecar
./scripts/rockport.sh upgrade --litellm             # Upgrade LiteLLM in place to the pinned version (keeps DB)
./scripts/rockport.sh start                         # Start a stopped instance
./scripts/rockport.sh stop                          # Stop the instance
./scripts/rockport.sh setup-claude                  # Create Anthropic-only key + Claude Code config
./scripts/rockport.sh destroy                       # Tear down everything
```

## Idle auto-stop

The instance automatically stops after 30 minutes of inactivity to save costs. The idle check considers both network traffic (NetworkIn < 500,000 bytes) and CPU utilisation (< 10%) — a high-CPU workload with low network traffic won't be stopped. A CloudWatch alarm fires if the idle-stop Lambda itself fails consecutively. When you need it again:

```bash
./scripts/rockport.sh start
```

The `start` command waits for the health endpoint to respond, so you know when it's ready. Services auto-start on boot — LiteLLM and the Cloudflare Tunnel reconnect within ~60 seconds.

To disable auto-stop, add to `terraform.tfvars`:

```hcl
enable_idle_shutdown = false
```

## Configuration

All settings are in `terraform/terraform.tfvars`. These variables have defaults and can be overridden:

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `eu-west-2` | AWS region |
| `tunnel_subdomain` | `llm` | Subdomain for the Cloudflare Tunnel |
| `instance_type` | `t3.small` | EC2 instance type |
| `litellm_version` | `1.100.1` | LiteLLM version to install |
| `cloudflared_version` | `2026.9.1` | Cloudflared version (pinned for stability) |
| `cloudflared_sha256` | *(matches version)* | SHA256 of cloudflared binary — must update when changing version |
| `bedrock_daily_budget` | `10` | Daily Bedrock spend alert threshold (USD) |
| `monthly_budget` | `30` | Monthly overall AWS budget alert threshold (USD) |
| `enable_idle_shutdown` | `true` | Auto-stop instance after inactivity |
| `idle_timeout_minutes` | `30` | Minutes of inactivity before auto-stop |
| `idle_threshold_bytes` | `500000` | Network bytes below which instance is considered idle |
| `video_max_concurrent_jobs` | `3` | Maximum concurrent video generation jobs per API key |
| `enable_guardrails` | `false` | Enable optional Bedrock Guardrails (content filtering, PII masking) |

Model configuration is in `config/litellm-config.yaml`. After editing, push changes to the running instance:

```bash
./scripts/rockport.sh config push
```

Budget and rate limit defaults are also in `litellm-config.yaml`:
- Global budget: `$10/day`
- Per-key budget: none unless `key create --budget N` (`$N/day`); internal users default to `$5/day`
- Rate limits: `60 RPM`, `200K TPM` per key

### Image generation

Image generation uses the OpenAI-compatible `/v1/images/generations` endpoint. Pass dimensions via the `size` parameter (e.g. `"1024x768"`).

All image models are Stability AI on Bedrock (us-west-2). Cheapest first — pick a bigger model when you need it:

| Model | Dimensions | Notes |
|-------|-----------|-------|
| Stable Image Core | Aspect ratio based | Text-to-image only, cheapest, good for drafts. JPEG/PNG |
| Stable Image Ultra | Aspect ratio based | Highest quality, supports image-to-image. JPEG/PNG |
| SD3.5 Large | Fixed 1024x1024 | `size` parameter ignored, returns JPEG not PNG |

```bash
curl -X POST https://<your-domain>/v1/images/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"stable-image-core","prompt":"a mountain landscape","n":1}'
```

Response contains `data[0].b64_json` with the base64-encoded image. Keys created with `--claude-only` cannot access image models.

Nova Canvas and Titan Image v2 were removed ahead of their Bedrock end-of-life dates (2026-09-30 and 2026-06-30). For image-to-image use Stable Image Ultra (`mode: "image-to-image"` with `image` and `strength`), or the Stability AI edit operations below.

#### Stability AI image editing (via LiteLLM)

All 13 Stability AI image edit operations use LiteLLM's native `/v1/images/edits` endpoint with `multipart/form-data`. Specify the operation via the `model` field. Keys created with `--claude-only` cannot access these models. All require a one-time Marketplace subscription.

| Model | Description | Cost |
|-------|-------------|------|
| `stability-structure` | Structure-guided generation (maintain composition) | $0.04 |
| `stability-sketch` | Sketch-to-image generation | $0.04 |
| `stability-style-transfer` | Transfer style between images | $0.06 |
| `stability-remove-background` | Remove background | $0.04 |
| `stability-search-replace` | Find and replace objects in an image | $0.04 |
| `stability-upscale` | Conservative upscale (max 1MP input) | $0.06 |
| `stability-style-guide` | Style-guided generation with reference image | $0.04 |
| `stability-inpaint` | Mask regions and replace with prompt-guided content | $0.04 |
| `stability-erase` | Mask regions and remove objects (no prompt needed) | $0.04 |
| `stability-creative-upscale` | Prompt-guided upscale to 4K (max 1MP input) | $0.06 |
| `stability-fast-upscale` | Deterministic 4x upscale (32–1536px, no prompt) | $0.04 |
| `stability-search-recolor` | Find objects by description and change their colour | $0.04 |
| `stability-outpaint` | Extend image directionally (left/right/up/down) | $0.04 |

```bash
curl -X POST https://<your-domain>/v1/images/edits \
  -H "Authorization: Bearer $KEY" \
  -F "model=stability-remove-background" \
  -F "image=@photo.png"
```

Response contains `data[0].b64_json` with the base64-encoded image. LiteLLM handles auth, budget enforcement, and spend tracking natively.

#### Palette & style control

No surviving Bedrock image model takes a hex palette directly, but LiteLLM forwards every extra field on `/v1/images/generations` and the Stability edit parameters on `/v1/images/edits` straight to Bedrock:

| Goal | Model | Parameters |
|---|---|---|
| Match a reference image's style (≈ `--sref`) | `stability-style-guide` (edits) | `image`, `prompt`, `fidelity` 0–1 (default 0.5), `negative_prompt`, `aspect_ratio`, `seed` |
| Stick to a hex palette | `POST /v1/images/palette` (sidecar) | `colors`, `weights`, `fidelity`, `layout`, `negative_prompt`, `aspect_ratio`, `seed` |
| Restyle an image from another image | `stability-style-transfer` (edits) | `image`, `style_image`, `style_strength`, `composition_fidelity`, `change_strength` |
| Recolour a region | `stability-search-recolor` (edits) | `image`, `select_prompt`, `prompt`, `grow_mask` |
| Steer colours in text-to-image | `stable-image-core` / `-ultra` / `sd3.5-large` | `negative_prompt`, `seed`, `aspect_ratio`; Ultra also `image` + `strength` |

```bash
# Style reference
curl -X POST https://<your-domain>/v1/images/edits -H "Authorization: Bearer $KEY" \
  -F model=stability-style-guide -F image=@reference.png -F "prompt=a lighthouse at dusk" -F fidelity=0.8

# Hex palette — sidecar renders a swatch, appends nearest CSS colour names to the prompt,
# and submits a stability-style-guide edit through LiteLLM with your key ($0.04)
curl -X POST https://<your-domain>/v1/images/palette -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a lighthouse at dusk","colors":["#1e3a5f","#f4d35e","#ee964b"],"weights":[2,1,1],"fidelity":0.7}'
```

`colors` takes 1–8 `#RRGGBB` values; `layout` is `stripes` (weighted bands, default) or `blocks`; `augment_prompt: false` skips the colour-name suffix. The response adds a `palette` object (normalised colours, names, final prompt, `swatch_b64`). Style Guide learns texture as well as colour from its reference — lower `fidelity` if results look banded, raise it if the palette drifts. Unverified against a live account as of 2026-09-12.

### Video generation

Video generation uses a sidecar service on port 4001 that drives Luma Ray2 on Bedrock. Bedrock's async invoke API (`StartAsyncInvoke` / `GetAsyncInvoke` with S3 output) isn't supported by LiteLLM's `/v1/videos` endpoint (which covers OpenAI, Azure, Gemini, Vertex and RunwayML only) — the sidecar handles this and can be decommissioned if LiteLLM adds Bedrock video support. The workflow is asynchronous — submit a job, then poll for completion. Nova Reel was removed ahead of its 2026-09-30 Bedrock end-of-life.

Defaults are the cheapest valid options (5 seconds, 540p, 16:9); opt into 9 seconds or 720p per request.

```bash
# Submit a video generation job
curl -X POST https://<your-domain>/v1/videos/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a tiger walking through snow",
    "duration": 5,
    "aspect_ratio": "16:9",
    "resolution": "540p",
    "loop": false
  }'
```

The POST returns `202 Accepted` with a job ID:

```json
{"id": "job_abc123", "status": "in_progress", "mode": "single_shot", "duration": 5, "estimated_cost": 3.75, "created_at": "..."}
```

Poll for completion:

```bash
curl https://<your-domain>/v1/videos/generations/job_abc123 \
  -H "Authorization: Bearer $KEY"
```

A completed job returns a presigned S3 URL (expires after 1 hour). Once the file is gone (7-day bucket lifecycle, or the model's bucket was retired) the job reports `"status": "expired"` with an `error` message.

```json
{"id": "job_abc123", "status": "completed", "mode": "single_shot", "duration": 5, "cost": 3.75, "url": "https://...s3.amazonaws.com/...", "url_expires_at": "..."}
```

**Image-to-video** — pass a start frame as a PNG or JPEG data URI in `image`, and optionally an end frame in `end_image` (both 512–4096px per side, max 25MB).

| Detail | Luma Ray2 |
|--------|-----------|
| Cost | $0.75/s (540p), $1.50/s (720p) |
| Resolution | 540p (default) or 720p |
| Aspect ratios | 16:9 (default), 9:16, 1:1, 4:3, 3:4, 21:9, 9:21 |
| Duration | 5s (default) or 9s |
| Prompt | Up to 5000 characters |
| Image-to-video | Start + optional end frame (512–4096px, PNG/JPEG, ≤25MB) |
| Loop | Yes (`loop: true`) |
| Concurrent jobs per key | 3 (configurable via `VIDEO_MAX_CONCURRENT_JOBS`) |
| Output storage | S3 bucket (us-west-2) with 7-day lifecycle |
| Presigned URL expiry | 1 hour |

Requires a one-time Marketplace subscription (same as the Stability AI models).

## CI/CD

Three GitHub Actions workflows:

**Validate** (`validate.yml`) — runs on pushes and PRs to `main` (paths: `terraform/`, `config/`, `scripts/`, `sidecar/`, `tests/`, CI config):
- `terraform fmt -check` and `terraform validate`
- ShellCheck on all shell scripts
- Gitleaks secrets scan
- Trivy IaC security scan
- Checkov policy-as-code scan
- pip-audit sidecar dependencies

**Deploy** (`deploy.yml`) — runs on push to `main` (paths: `terraform/`, `config/`, `scripts/`, `sidecar/`, `tests/`):
- `terraform plan` on PRs (saves plan as artifact)
- Plans and applies on merge to `main`
- Smoke tests after deploy

**Release** (`release.yml`) — runs on `v*` tags; creates a GitHub release with commit-log notes since the previous tag.

CI uses GitHub OIDC for AWS authentication. Set `AWS_ROLE_ARN` in GitHub repository secrets to an IAM role with OIDC trust policy. Also set `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_API_TOKEN` as secrets.

## Security design

Rockport is designed so that the proxy has no direct internet exposure. Every layer adds defense in depth:

**Network isolation** — The EC2 instance has zero inbound security group rules. No SSH, no HTTP, nothing. All traffic reaches LiteLLM exclusively through Cloudflare Tunnel, which maintains an outbound-only connection to Cloudflare's edge.

**Localhost-only binding** — LiteLLM listens on `127.0.0.1:4000`, not `0.0.0.0`. Even if the security group were misconfigured, the service would not accept external connections directly.

**Admin UI disabled** — The LiteLLM admin dashboard is disabled via `disable_admin_ui: true` and Swagger/ReDoc docs are disabled via `NO_DOCS=True` / `NO_REDOC=True` environment variables. A Cloudflare WAF allowlist (`terraform/waf.tf`) blocks all paths except those needed by Claude Code, image generation, image editing, palette generation, video generation, and the admin CLI — only `/v1/chat/completions`, `/v1/models`, `/v1/messages`, `/v1/images/generations`, `/v1/images/edits`, `/v1/images/palette`, `/v1/videos/*`, `/key/*`, `/health` (exact match), `/spend/*`, and a handful of other operational paths are reachable. Everything else (admin UI, OpenAPI schema, routes list, SSO, SCIM, debug endpoints, etc.) returns 403 at the Cloudflare edge.

**Key separation** — The master key (stored in SSM Parameter Store) is only used by the admin CLI. Users get virtual keys with per-key daily budgets and rate limits. Keys created with `--claude-only` (or via `setup-claude`) are restricted to Anthropic models only. Keys without this flag get access to all models including image generation. Virtual keys can only call model endpoints — they cannot create other keys, view spend, or manage the proxy.

**Secrets handling** — All secrets are auto-generated — no manual credential creation beyond the Cloudflare API token. The master key is generated during `init`, the Cloudflare Access service token and tunnel token are created by `terraform apply`, the database password is generated during EC2 bootstrap, and the deployer IAM access keys are created during `init`. All are stored as SSM SecureString parameters (encrypted at rest with AWS KMS) or as Terraform-managed resources. The database password never appears in logs. Environment files are written with `umask 077` to prevent brief permission windows.

**Systemd hardening** — All services (LiteLLM, cloudflared, video sidecar) run as dedicated non-root users with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `SystemCallFilter=@system-service`, `PrivateDevices=yes`, `RestrictNamespaces=yes`, `CapabilityBoundingSet=` (all capabilities dropped), `ProtectControlGroups=yes`, `RestrictSUIDSGID=yes`, and memory limits. The `litellm` user's home directory is `/var/lib/litellm` (not `/home/litellm`) so prisma cache is accessible under `ProtectHome=yes`.

**IMDSv2 enforced** — The instance metadata service requires session tokens (hop limit 1), preventing SSRF-based credential theft.

**Transport security** — "Always Use HTTPS" is enabled in the Cloudflare dashboard (HTTP → 301). A Terraform response-header rule (`terraform/headers.tf`) adds HSTS (6 months max-age) and `X-Content-Type-Options: nosniff` to every proxied response.

**Least-privilege IAM** — The deployer IAM policies (`terraform/deployer-policies/`) scope EC2 and SSM mutating actions to resources tagged `Project=rockport`. Read-only Describe actions use `Resource: *` as required by AWS. An explicit Deny statement prevents the deployer from attaching any AWS-managed policy (e.g. `AdministratorAccess`) to rockport roles — only rockport-prefixed custom policies are allowed, blocking privilege escalation via the CI/CD pipeline. The instance role is limited to Bedrock invoke and SSM parameter access.

**CI security scanning** — Every push runs Trivy (IaC misconfiguration), Checkov (policy-as-code), Gitleaks (secrets scanning), and pip-audit (sidecar dependency vulnerabilities) against the codebase. Skipped checks are documented with justifications in `.checkov.yaml`.

**Cloudflare Access pre-authentication** — A Cloudflare Access application (`terraform/access.tf`) requires a service token for all requests. Clients must send `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers or Cloudflare returns 403 before traffic reaches the tunnel. This adds a second credential layer beyond API keys — even if an API key leaks, requests are blocked without the service token. Token values are sensitive Terraform outputs. To rotate: create a new service token, update all clients, then remove the old one.

**Database authentication** — PostgreSQL uses SCRAM-SHA-256 for all client authentication (not md5). Connections are localhost-only with no TLS (traffic never leaves the kernel's loopback interface).

### What's exposed

All requests require both a valid Cloudflare Access service token and a valid LiteLLM API key. A Cloudflare WAF allowlist further restricts traffic to only the paths Claude Code and the admin CLI need. All other paths (admin UI, API docs, debug endpoints, SCIM, SSO, etc.) are blocked with 403 at the edge. The remaining attack surface is:

- Brute-force key guessing (mitigated by key length — master key is `sk-` + 48 hex characters; virtual keys use LiteLLM's default token format)
- Cloudflare-level DDoS (mitigated by Cloudflare's built-in protection)
- Service token compromise (mitigated by token rotation via Terraform)

## Smoke tests

```bash
# With CF Access headers (required when Cloudflare Access is enabled)
./tests/smoke-test.sh https://<your-domain> <cf-client-id> <cf-client-secret>

# Or via environment variables
export CF_ACCESS_CLIENT_ID=<cf-client-id>
export CF_ACCESS_CLIENT_SECRET=<cf-client-secret>
./tests/smoke-test.sh https://<your-domain>
```

The smoke test creates and cleans up its own temporary API key via the admin CLI. It costs ~$0.05 per run (two chat + one image generation call).

## Security Testing

A 13-module pentest toolkit tests the full attack surface through Cloudflare: WAF allowlist, Access tokens, API key auth, tunnel routing, sidecar endpoints, infrastructure security, and supply chain integrity.

```bash
# Install optional tools (nmap, nuclei, ffuf, testssl.sh)
./pentest/install.sh

# Run a full security scan
./pentest/pentest.sh run rockport

# Run a single module
./pentest/pentest.sh run rockport --module waf

# View the latest report
./pentest/pentest.sh report rockport
```

Scans cost under $0.25 in API calls. A temp API key is created and auto-revoked per scan. See `CLAUDE.md` for full details on modules and configuration.

## Teardown

```bash
./scripts/rockport.sh destroy
```

This removes all AWS resources, Cloudflare Tunnel + DNS record, and SSM parameters (master key, database password).
