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

Or install manually: AWS CLI v2, Session Manager plugin, Terraform >= 1.14, GitHub CLI.

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

## Smoke tests

```bash
./tests/smoke-test.sh https://<your-domain> sk-<your-key>
```

## Teardown

```bash
./scripts/rockport.sh destroy
```

This removes all AWS resources and the Cloudflare Tunnel + DNS record. SSM parameters (`/rockport/master-key`) must be deleted separately if desired:

```bash
aws ssm delete-parameter --name "/rockport/master-key" --region <your-region>
```
