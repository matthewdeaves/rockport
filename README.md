# Rockport

LiteLLM proxy on EC2 that gives Claude Code access to any Bedrock model through a single endpoint. Cloudflare Tunnel provides HTTPS ingress with zero inbound ports. Terraform manages everything.

## What you get

- Claude Code connects via `ANTHROPIC_BASE_URL` to your own proxy
- Anthropic (Opus 4.6, Sonnet 4.6, Haiku 4.5), DeepSeek V3.2, Qwen3 Coder 480B, Kimi K2.5, Nova Pro/Lite/Micro on Bedrock
- Virtual API keys with per-key budgets and rate limits
- Zero inbound security group rules — all traffic flows through Cloudflare Tunnel
- Daily EBS snapshots with 7-day retention
- Auto-recovery on system failure
- Auto-stop after 30 minutes of inactivity (saves costs when idle)
- Daily Bedrock budget alerts + monthly overall AWS budget alerts
- `rockport` CLI for key management, logs, deploys, start/stop

## Setup

### 1. Install tools

```bash
./scripts/setup.sh
```

Or install manually: AWS CLI v2, Session Manager plugin, Terraform >= 1.14, jq, GitHub CLI.

### 2. Configure AWS credentials

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: eu-west-2
# Default output format: json
```

### 3. Enable Bedrock model access

Go to AWS Console > Bedrock > Model access (in your chosen region) and enable the models you want. At minimum enable Claude Sonnet and Claude Haiku.

### 4. Set Cloudflare credentials

Create a Cloudflare API token at https://dash.cloudflare.com/profile/api-tokens with these permissions:
- **Zone / DNS / Edit**
- **Account / Cloudflare Tunnel / Edit**
- **Account / Zero Trust / Edit**

```bash
export CLOUDFLARE_API_TOKEN="<your-token>"
```

### 5. Initialize

```bash
./scripts/rockport.sh init
```

This prompts for your domain, Cloudflare IDs, region, and email. It creates `terraform/terraform.tfvars` and stores a master key in SSM.

### 6. Deploy

```bash
./scripts/rockport.sh deploy
```

Takes ~2 minutes for Terraform, then ~5 minutes for the instance to bootstrap.

### 7. Verify and configure Claude Code

```bash
# Wait for bootstrap, then:
./scripts/rockport.sh status

# Generate a key and configure Claude Code:
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
./scripts/rockport.sh key create <name> [--budget N] # Create API key (optional $/day limit)
./scripts/rockport.sh key list                      # List all keys with spend
./scripts/rockport.sh key info <key>                # Key details + spend
./scripts/rockport.sh key revoke <key>              # Revoke a key
./scripts/rockport.sh spend                         # Global spend summary
./scripts/rockport.sh spend keys                    # Spend breakdown by key
./scripts/rockport.sh config push                   # Push config to instance + restart
./scripts/rockport.sh logs                          # Stream LiteLLM logs
./scripts/rockport.sh upgrade                       # Restart LiteLLM (config changes)
./scripts/rockport.sh start                         # Start a stopped instance
./scripts/rockport.sh stop                          # Stop the instance
./scripts/rockport.sh setup-claude                  # Create key + show Claude Code config
./scripts/rockport.sh destroy                       # Tear down everything
```

## Idle auto-stop

The instance automatically stops after 30 minutes of inactivity to save costs. When you need it again:

```bash
./scripts/rockport.sh start
```

Services auto-start on boot — LiteLLM and the Cloudflare Tunnel reconnect within ~60 seconds.

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

**Admin UI disabled** — The LiteLLM admin dashboard (`/ui`) is disabled via `disable_admin_ui: true`. This eliminates the largest web attack surface: session management, SSO bypass, CSRF, and the additional frontend dependencies. All administration is done through the `rockport` CLI, which calls the API with the master key.

**Key separation** — The master key (stored in SSM Parameter Store) is only used by the admin CLI. Users get virtual keys with per-key daily budgets and rate limits. Virtual keys can only call model endpoints — they cannot create other keys, view spend, or manage the proxy.

**Secrets handling** — The master key and tunnel token are stored as SSM SecureString parameters (encrypted at rest with AWS KMS). The database password is generated on the instance during bootstrap, stored in SSM for recovery, and never appears in logs. Environment files are written with `umask 077` to prevent brief permission windows.

**Systemd hardening** — Both LiteLLM and cloudflared run as dedicated non-root users with `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, and `PrivateTmp=yes`.

**IMDSv2 enforced** — The instance metadata service requires session tokens (hop limit 1), preventing SSRF-based credential theft.

**CI security scanning** — Every push runs Trivy (IaC misconfiguration) and Checkov (policy-as-code) against the Terraform. Skipped checks are documented with justifications in `.checkov.yaml`.

### What's exposed

Anyone who discovers the domain can reach the LiteLLM API through Cloudflare. Without a valid key, all requests return 401. The attack surface is:

- Unauthenticated probing (health endpoint returns 401)
- Brute-force key guessing (mitigated by key length — master key is `sk-` + 48 hex characters; virtual keys use LiteLLM's default token format)
- Cloudflare-level DDoS (mitigated by Cloudflare's built-in protection)

### Optional: Cloudflare Access for pre-authentication

For an additional layer, you can put a Cloudflare Access application in front of the tunnel. This would require authentication (email OTP, SSO, or mTLS certificate) before traffic even reaches LiteLLM.

**Email verification** — Cloudflare Access can gate the domain behind a one-time-password sent to allowed email addresses. Any request without a valid Cloudflare Access JWT is blocked at the edge before it reaches your instance. This is useful if you want to restrict access to a known set of people beyond just key auth. The downside is that Claude Code doesn't natively handle Cloudflare Access authentication, so you'd need to generate a service token and pass it as a header, or use `cloudflared access` to create a local tunnel on the client side.

**mTLS (mutual TLS)** — Cloudflare can require client certificates signed by a CA you upload. Only clients presenting a valid certificate can establish a connection. This is the strongest option — even if someone discovers your domain and somehow obtains an API key, they still can't connect without the certificate. The trade-off is certificate distribution and rotation complexity.

**Service tokens** — A simpler alternative: create a Cloudflare Access service token (client ID + secret) and configure Claude Code to send it as headers. This adds a second credential layer without the complexity of mTLS. Configure via Cloudflare Zero Trust dashboard > Access > Applications.

For a personal or small-team proxy where the API keys are closely held, the current setup (key auth + Cloudflare DDoS protection + no inbound ports) is sufficient. Cloudflare Access adds value when you want to share access more broadly or need to satisfy compliance requirements.

## Smoke tests

```bash
./tests/smoke-test.sh https://<your-domain> sk-<your-key>
```

## Teardown

```bash
./scripts/rockport.sh destroy
```

This removes all AWS resources, Cloudflare Tunnel + DNS record, and SSM parameters (master key, database password).
