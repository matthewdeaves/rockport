# Rockport

LiteLLM proxy on EC2 that gives Claude Code access to any Bedrock model through a single endpoint. Cloudflare Tunnel provides HTTPS ingress with zero inbound ports. Terraform manages everything.

## Architecture

![Architecture Overview](docs/rockport_architecture_overview.svg)

![Request Data Flow](docs/rockport_request_dataflow.svg)

## What you get

- Claude Code connects via `ANTHROPIC_BASE_URL` to your own proxy
- Anthropic (Opus 4.6, Sonnet 4.6, Haiku 4.5), DeepSeek V3.2, Qwen3 Coder 480B, Kimi K2.5, Nova Pro/Lite/Micro on Bedrock
- Image generation and editing via OpenAI-compatible `/v1/images/generations` and `/v1/images/edits` (Nova Canvas, Titan Image v2, SD3.5 Large)
- Virtual API keys with per-key budgets, rate limits, and model restrictions
- Zero inbound security group rules — all traffic flows through Cloudflare Tunnel
- Daily EBS snapshots with 7-day retention
- Auto-recovery on system failure
- Auto-stop after 30 minutes of inactivity (with 10-minute grace period after boot)
- Daily Bedrock budget alerts + monthly overall AWS budget alerts
- `rockport` CLI for key management, logs, deploys, start/stop

## Prerequisites

Before you start, you need:

1. **An AWS account** with an IAM user that has admin access (or root credentials for first-time setup)
2. **A Cloudflare account** with a domain — you'll create an API token and a tunnel
3. **Bedrock model access** — chat models auto-enable on first use. Stability AI image models require a one-time Marketplace subscription (use them once in the Bedrock playground to activate)

### Cloudflare API token

Create a token at https://dash.cloudflare.com/profile/api-tokens with these permissions:
- **Zone / DNS / Edit**
- **Zone / Zone WAF / Edit**
- **Account / Cloudflare Tunnel / Edit**
- **Account / Zero Trust / Edit**

You'll also need your Cloudflare **Zone ID** and **Account ID** (found on the domain overview page).

### Bedrock model access

Serverless foundation models auto-enable on first invocation. For Stability AI image models (SD3.5 Large), open the model in the Bedrock playground once to trigger the Marketplace subscription. Chat models (Claude, Nova, etc.) work immediately.

## Setup

### 1. Install tools

```bash
./scripts/setup.sh
```

This installs AWS CLI v2, Session Manager plugin, Terraform, jq, and GitHub CLI. Or install them manually.

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

The `init` command will create a dedicated `rockport-deployer` IAM user with scoped permissions and configure a `rockport` AWS CLI profile automatically. After init completes, you can delete the root access keys — all subsequent commands use the `rockport` profile.

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
- Creates a scoped `RockportDeployerAccess` IAM policy (least-privilege — no wildcard permissions)
- Creates a `rockport-deployer` IAM user and configures a `rockport` AWS CLI profile
- Generates a master API key and stores it in SSM Parameter Store
- Creates an S3 bucket for Terraform state

All subsequent `rockport.sh` commands automatically use the `rockport` AWS CLI profile — no need to export credentials.

If you already have a `terraform.tfvars` from a previous setup, init will ask whether to keep it and just ensure the IAM policy, master key, and state bucket exist.

### 4. Deploy

```bash
./scripts/rockport.sh deploy
```

Takes ~2 minutes for Terraform, then ~5 minutes for the EC2 instance to bootstrap (installs PostgreSQL, LiteLLM, cloudflared).

### 5. Verify and configure Claude Code

```bash
# Wait for bootstrap (~5 min), then check health:
./scripts/rockport.sh status

# Generate a key and get Claude Code config:
./scripts/rockport.sh setup-claude

# Copy the generated settings file:
cp config/claude-code-settings-<key-name>.json ~/.claude/settings.json
```

Launch Claude Code. Default model routes to Opus 4.6.

## Admin CLI

```bash
./scripts/rockport.sh init                          # Interactive setup
./scripts/rockport.sh deploy                        # Run terraform apply
./scripts/rockport.sh status                        # Health check + model list
./scripts/rockport.sh models                        # List available models
./scripts/rockport.sh key create <name> [--budget N] [--claude-only] # Create API key
./scripts/rockport.sh key list                      # List all keys with spend
./scripts/rockport.sh key info <key>                # Key details + spend
./scripts/rockport.sh key revoke <key>              # Revoke a key
./scripts/rockport.sh spend                         # Global spend summary
./scripts/rockport.sh spend keys                    # Spend breakdown by key
./scripts/rockport.sh monitor                       # Key status + recent requests
./scripts/rockport.sh monitor --live                # Live dashboard (auto-refresh)
./scripts/rockport.sh config push                   # Push config to instance + restart
./scripts/rockport.sh logs                          # Stream LiteLLM logs
./scripts/rockport.sh upgrade                       # Restart LiteLLM (config changes)
./scripts/rockport.sh start                         # Start a stopped instance
./scripts/rockport.sh stop                          # Stop the instance
./scripts/rockport.sh setup-claude                  # Create Anthropic-only key + Claude Code config
./scripts/rockport.sh destroy                       # Tear down everything
```

## Idle auto-stop

The instance automatically stops after 30 minutes of inactivity to save costs. When you need it again:

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
| `instance_type` | `t3.small` | EC2 instance type |
| `litellm_version` | `1.82.2` | LiteLLM version to install |
| `cloudflared_version` | `2026.3.0` | Cloudflared version (pinned for stability) |
| `bedrock_daily_budget` | `10` | Daily Bedrock spend alert threshold (USD) |
| `monthly_budget` | `30` | Monthly overall AWS budget alert threshold (USD) |
| `enable_idle_shutdown` | `true` | Auto-stop instance after inactivity |
| `idle_timeout_minutes` | `30` | Minutes of inactivity before auto-stop |
| `idle_threshold_bytes` | `500000` | Network bytes below which instance is considered idle |

Model configuration is in `config/litellm-config.yaml`. After editing, push changes to the running instance:

```bash
./scripts/rockport.sh config push
```

Budget and rate limit defaults are also in `litellm-config.yaml`:
- Global budget: `$10/day`
- Per-key default budget: `$5/day`
- Rate limits: `60 RPM`, `200K TPM` per key

### Image generation

Image generation uses the OpenAI-compatible `/v1/images/generations` endpoint. Pass dimensions via the `size` parameter (e.g. `"1024x768"`).

| Model | Dimensions | Constraint | Default |
|-------|-----------|------------|---------|
| Nova Canvas | 320–2048 per side | Must be divisible by 64, max 4.1MP total | 1024x1024 |
| Titan Image v2 | Preset sizes | 256, 512, 768, 1024, 1152, 1408 combinations | 512x512 |
| SD3.5 Large | Fixed 1024x1024 | `size` parameter ignored, returns JPEG not PNG | 1024x1024 |

```bash
curl -X POST https://<your-domain>/v1/images/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"nova-canvas","prompt":"a mountain landscape","size":"1024x768","n":1}'
```

Response contains `data[0].b64_json` with the base64-encoded PNG. Keys created with `--claude-only` cannot access image models.

#### Image-to-image (conditioned generation)

Pass a source image to modify it with a text prompt. Use the same `/v1/images/generations` endpoint with model-specific parameters:

**Nova Canvas** — pass `conditionImage` (base64) in `textToImageParams`:

```bash
curl -X POST https://<your-domain>/v1/images/generations \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nova-canvas",
    "prompt": "transform into a watercolor painting",
    "size": "512x512",
    "n": 1,
    "textToImageParams": {"conditionImage": "<base64-encoded-image>"}
  }'
```

Source images must be base64-encoded PNG or JPEG. Nova Canvas requires minimum 320px per side. SD3.5 Large also supports `mode: "image-to-image"` with an `image` and `strength` parameter, but always outputs 1024x1024 JPEG — Nova Canvas is recommended for image-to-image.

**Note:** `/v1/images/edits` is not supported — LiteLLM 1.82.2 only supports that endpoint for Stability AI models, not Bedrock's Nova Canvas or Titan. Use `/v1/images/generations` with `conditionImage` instead.

## CI/CD

Two GitHub Actions workflows run on push to `main`:

**Validate** (`validate.yml`) — runs on every push and PR:
- `terraform fmt -check` and `terraform validate`
- ShellCheck on all `.sh` files
- Trivy IaC security scan
- Checkov policy-as-code scan

**Deploy** (`deploy.yml`) — runs on push to `main` (paths: `terraform/`, `config/`, `scripts/`):
- `terraform plan` on PRs (comments the plan on the PR)
- `terraform apply -auto-approve` on merge to `main`
- Smoke tests after deploy

CI uses GitHub OIDC for AWS authentication. Set `AWS_ROLE_ARN` in GitHub repository secrets to an IAM role with OIDC trust policy. Also set `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_API_TOKEN` as secrets.

## Security design

Rockport is designed so that the proxy has no direct internet exposure. Every layer adds defense in depth:

**Network isolation** — The EC2 instance has zero inbound security group rules. No SSH, no HTTP, nothing. All traffic reaches LiteLLM exclusively through Cloudflare Tunnel, which maintains an outbound-only connection to Cloudflare's edge.

**Localhost-only binding** — LiteLLM listens on `127.0.0.1:4000`, not `0.0.0.0`. Even if the security group were misconfigured, the service would not accept external connections directly.

**Admin UI disabled** — The LiteLLM admin dashboard is disabled via `disable_admin_ui: true` and Swagger/ReDoc docs are disabled via `NO_DOCS=True` / `NO_REDOC=True` environment variables. A Cloudflare WAF allowlist (`terraform/waf.tf`) blocks all paths except those needed by Claude Code, image generation, and the admin CLI — only `/v1/chat/completions`, `/v1/models`, `/v1/messages`, `/v1/images/generations`, `/key/*`, `/health/*`, `/spend/*`, and a handful of other operational paths are reachable. Everything else (admin UI, OpenAPI schema, routes list, SSO, SCIM, debug endpoints, etc.) returns 403 at the Cloudflare edge.

**Key separation** — The master key (stored in SSM Parameter Store) is only used by the admin CLI. Users get virtual keys with per-key daily budgets and rate limits. Keys created with `--claude-only` (or via `setup-claude`) are restricted to Anthropic models only. Keys without this flag get access to all models including image generation. Virtual keys can only call model endpoints — they cannot create other keys, view spend, or manage the proxy.

**Secrets handling** — The master key and tunnel token are stored as SSM SecureString parameters (encrypted at rest with AWS KMS). The database password is generated on the instance during bootstrap, stored in SSM for recovery, and never appears in logs. Environment files are written with `umask 077` to prevent brief permission windows.

**Systemd hardening** — Both LiteLLM and cloudflared run as dedicated non-root users with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and memory limits. The `litellm` user's home directory is `/var/lib/litellm` (not `/home/litellm`) so prisma cache is accessible under `ProtectHome=yes`.

**IMDSv2 enforced** — The instance metadata service requires session tokens (hop limit 1), preventing SSRF-based credential theft.

**Transport security** — HSTS (6 months max-age) and "Always Use HTTPS" are enabled in Cloudflare, enforcing HTTPS-only access. HTTP requests are redirected with 301.

**Least-privilege IAM** — The deployer IAM policy (`terraform/rockport-deployer-policy.json`) scopes EC2 and SSM mutating actions to resources tagged `Project=rockport`. Read-only Describe actions use `Resource: *` as required by AWS. The instance role is limited to Bedrock invoke and SSM parameter access.

**CI security scanning** — Every push runs Trivy (IaC misconfiguration) and Checkov (policy-as-code) against the Terraform. Skipped checks are documented with justifications in `.checkov.yaml`.

### What's exposed

A Cloudflare WAF allowlist restricts the proxy to only the paths Claude Code and the admin CLI need. All other paths (admin UI, API docs, debug endpoints, SCIM, SSO, etc.) are blocked with 403 at the edge. On the allowed paths, all requests without a valid key return 401. The remaining attack surface is:

- Brute-force key guessing (mitigated by key length — master key is `sk-` + 48 hex characters; virtual keys use LiteLLM's default token format)
- Cloudflare-level DDoS (mitigated by Cloudflare's built-in protection)

See [docs/future-ideas.md](docs/future-ideas.md) for additional hardening options like Cloudflare Access pre-authentication.

## Smoke tests

```bash
./tests/smoke-test.sh https://<your-domain> sk-<your-key>
```

## Teardown

```bash
./scripts/rockport.sh destroy
```

This removes all AWS resources, Cloudflare Tunnel + DNS record, and SSM parameters (master key, database password).
