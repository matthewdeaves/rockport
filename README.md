# Rockport

LiteLLM proxy on EC2 that gives Claude Code access to any Bedrock model through a single endpoint. Cloudflare Tunnel provides HTTPS ingress with zero inbound ports. Terraform manages everything.

## What you get

- Claude Code connects via `ANTHROPIC_BASE_URL` to your own proxy
- Anthropic (Opus 4.6, Sonnet 4.6, Haiku 4.5), DeepSeek V3.2, Qwen3 Coder 480B, Kimi K2.5, Nova Pro/Lite/Micro on Bedrock
- Virtual API keys for per-user access control and spend tracking
- Zero inbound security group rules — all traffic flows through Cloudflare Tunnel
- Daily EBS snapshots with 7-day retention
- Auto-recovery on system failure
- `rockport` CLI for key management, logs, deploys

## Cost

~£15/month total: EC2 `t4g.small` (~£10.53), EBS gp3 20GB (~£1.60), snapshots (~£1-2), Cloudflare Tunnel (free).

## Setup

### 1. Install tools

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/aws-install
sudo /tmp/aws-install/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws-install

# Session Manager plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
rm /tmp/session-manager-plugin.deb

# Terraform 1.14.7 (binary install — works on any distro)
wget https://releases.hashicorp.com/terraform/1.14.7/terraform_1.14.7_linux_amd64.zip -O /tmp/terraform.zip
unzip /tmp/terraform.zip -d /tmp
sudo mv /tmp/terraform /usr/local/bin/
rm /tmp/terraform.zip
```

Verify everything installed:

```bash
aws --version
session-manager-plugin --version
terraform --version
```

### 2. Configure AWS credentials

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: eu-west-2
# Default output format: json
```

### 3. Enable Bedrock model access

Go to AWS Console → Bedrock → Model access (in `eu-west-2`) and enable the models you want. At minimum enable Claude Sonnet and Claude Haiku.

### 4. Store the LiteLLM master key in SSM

```bash
aws ssm put-parameter \
  --name "/rockport/master-key" \
  --value "sk-$(openssl rand -hex 24)" \
  --type SecureString \
  --region eu-west-2
```

### 5. Set Cloudflare credentials

You need your Cloudflare Account ID and Zone ID (both visible on the domain's overview page in the Cloudflare dashboard), plus an API token.

Create a Cloudflare API token at https://dash.cloudflare.com/profile/api-tokens with these permissions:
- **Zone / DNS / Edit**
- **Account / Cloudflare Tunnel / Edit**
- **Account / Zero Trust / Edit**

```bash
export CLOUDFLARE_API_TOKEN="<your-token>"
```

### 6. Deploy

```bash
cd terraform
terraform init
terraform apply \
  -var cloudflare_zone_id="<your-zone-id>" \
  -var cloudflare_account_id="<your-account-id>"
```

This takes ~2 minutes for Terraform, then ~5 minutes for the instance to bootstrap (install PostgreSQL, LiteLLM, cloudflared).

### 7. Verify

```bash
# Wait for bootstrap to complete, then:
curl https://llm.matthewdeaves.com/health
# Should return: {"status": "healthy"}
```

### 8. Generate your API key

```bash
MASTER_KEY=$(aws ssm get-parameter \
  --name "/rockport/master-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region eu-west-2)

curl -X POST https://llm.matthewdeaves.com/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_name": "matt-claude-code"}'
```

Save the returned `sk-...` key.

### 9. Configure Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://llm.matthewdeaves.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-<your-virtual-key>"
  }
}
```

Launch Claude Code. Default model routes to Opus 4.6. Use `claude --model deepseek-v3.2` (or any model name from the config) to try other Bedrock models.

## Admin CLI

```bash
./scripts/rockport.sh status              # Health check + model list
./scripts/rockport.sh models              # List available models
./scripts/rockport.sh key create <name>   # Create API key
./scripts/rockport.sh key list            # List all keys
./scripts/rockport.sh key info <key>      # Key details + spend
./scripts/rockport.sh key revoke <key>    # Revoke a key
./scripts/rockport.sh spend               # Global spend summary
./scripts/rockport.sh config push         # Push config to instance + restart
./scripts/rockport.sh logs                # Stream LiteLLM logs
./scripts/rockport.sh deploy              # Run terraform apply
./scripts/rockport.sh upgrade             # Restart LiteLLM (config changes)
./scripts/rockport.sh destroy             # Tear down everything
```

## Smoke tests

After deployment, run the smoke tests to verify everything works:

```bash
./tests/smoke-test.sh https://llm.matthewdeaves.com sk-<your-key>
```

## Teardown

```bash
./scripts/rockport.sh destroy
```

This removes all AWS resources and the Cloudflare Tunnel + DNS record. SSM parameters (`/rockport/master-key`) must be deleted separately if desired:

```bash
aws ssm delete-parameter --name "/rockport/master-key" --region eu-west-2
```
