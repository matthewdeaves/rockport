# Quickstart: LiteLLM Bedrock Proxy

**Date**: 2026-03-13
**Feature**: 001-litellm-bedrock-proxy

## Prerequisites

1. **AWS account** with Bedrock model access enabled in
   `eu-west-2` (London). Enable the models you want via the
   AWS Console → Bedrock → Model access.
2. **Cloudflare account** managing `matthewdeaves.com`.
   Create a Cloudflare API token with Tunnel:Edit and DNS:Edit
   permissions.
3. **Terraform** installed (v1.14+).
4. **AWS CLI** configured with credentials for your account.
5. **Session Manager plugin** installed for `aws ssm` access.

## Deploy

### 1. Clone and configure

```bash
git clone <repo-url> rockport && cd rockport
```

### 2. Store secrets in SSM

```bash
# Generate a master key (must start with sk-)
aws ssm put-parameter \
  --name "/rockport/master-key" \
  --value "sk-$(openssl rand -hex 24)" \
  --type SecureString \
  --region eu-west-2

# Store Cloudflare API token (for Terraform)
export CLOUDFLARE_API_TOKEN="<your-cloudflare-api-token>"
```

### 3. Deploy infrastructure

```bash
cd terraform
terraform init
terraform apply \
  -var cloudflare_zone_id="<your-zone-id>" \
  -var cloudflare_account_id="<your-account-id>"
```

This creates: EC2 instance, security group, IAM role, Cloudflare
Tunnel, DNS record, DLM snapshot policy. The instance bootstraps
itself (installs PostgreSQL, LiteLLM, cloudflared).

### 4. Wait for bootstrap (~5 minutes)

```bash
# Check if the service is up
curl https://llm.matthewdeaves.com/health
```

### 5. Generate your API key

```bash
# Get master key from SSM
MASTER_KEY=$(aws ssm get-parameter \
  --name "/rockport/master-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region eu-west-2)

# Generate a virtual key
curl -X POST https://llm.matthewdeaves.com/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_name": "matt-claude-code"}'
```

Save the returned `sk-...` key.

## Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://llm.matthewdeaves.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-<your-virtual-key>"
  }
}
```

Launch Claude Code. Default routes to Opus 4.6 via Bedrock.
Use `claude --model deepseek-v3.2` to try other models.

## Common Admin Tasks

### Create a key for another user

```bash
curl -X POST https://llm.matthewdeaves.com/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_name": "alice"}'
```

### Revoke a key

```bash
curl -X POST https://llm.matthewdeaves.com/key/delete \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-key-to-revoke"]}'
```

### Add a Bedrock model

Edit `config/litellm-config.yaml`, add the model entry, then redeploy:

```bash
./scripts/rockport.sh deploy
```

Or for config-only changes without full redeploy:

```bash
./scripts/rockport.sh upgrade
```

### View logs

```bash
./scripts/rockport.sh logs
```

### Using the rockport CLI

```bash
./scripts/rockport.sh status          # Health check + model list
./scripts/rockport.sh key create bob  # Create a key
./scripts/rockport.sh key list        # List all keys with spend
./scripts/rockport.sh key info sk-x   # Key details + spend
./scripts/rockport.sh spend           # Global spend summary
./scripts/rockport.sh models          # List models
./scripts/rockport.sh config push     # Push config to instance + restart
```

## Teardown

```bash
./scripts/rockport.sh destroy
```

All AWS resources and the Cloudflare Tunnel + DNS record are
removed. SSM parameters must be deleted separately if desired.
