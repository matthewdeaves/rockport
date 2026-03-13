# Research: LiteLLM Bedrock Proxy

**Date**: 2026-03-13
**Feature**: 001-litellm-bedrock-proxy

## R1: Claude Code Custom Endpoint

**Decision**: Claude Code connects via `ANTHROPIC_BASE_URL` using
the Anthropic Messages API (`/v1/messages`), not OpenAI format.

**Rationale**: Claude Code natively uses the Anthropic API. It
sends requests to `/v1/messages` with `x-api-key` header. LiteLLM
proxy supports this endpoint format, so Claude Code →
LiteLLM `/v1/messages` → Bedrock works without translation.

**Configuration**:
- Settings file: `~/.claude/settings.json`
- Key env vars: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`
- Note: `ANTHROPIC_API_KEY` does NOT work — must use `ANTHROPIC_AUTH_TOKEN`
- Model switching: Claude Code hardcodes model IDs (`claude-sonnet-4-5-20250929`,
  `claude-opus-4-5-20251101`, `claude-haiku-4-5-20251001`). LiteLLM aliases
  in config.yaml map these to latest 4.6 Bedrock models.
- `claude --model <name>` overrides the model for a session.

**Alternatives considered**: OpenAI-compatible endpoint
(`/v1/chat/completions`) — not needed since Claude Code uses
Anthropic format natively.

## R2: Prisma Generate User Context

**Decision**: Run `prisma generate` as the `litellm` system user, not root.

**Rationale**: Prisma Python client hardcodes `BINARY_PATHS` in the generated
client at `site-packages/prisma/client.py`. These paths include
`$HOME/.cache/prisma-python/...`. If generated as root, the paths point to
`/root/.cache/` which the `litellm` user can't access, causing
`NotConnectedError` at runtime.

**Implementation**:
```bash
chown -R litellm:litellm /usr/local/lib/python3.11/site-packages/prisma
HOME=/home/litellm sudo -u litellm -E prisma generate \
  --schema /usr/local/lib/python3.11/site-packages/litellm/proxy/schema.prisma
```

**Alternatives considered**:
- Symlink `/root/.cache` — fragile, doesn't survive updates
- Run LiteLLM as root — security violation
- Docker container — adds complexity, memory overhead on t3.small

## R3: LiteLLM Bedrock Configuration

**Decision**: LiteLLM with `bedrock/` prefix, IAM role auth,
model aliases in `config.yaml`.

**Rationale**: LiteLLM auto-uses EC2 instance IAM role for
Bedrock — no credentials in config. Model aliases map friendly
names to Bedrock model IDs. PostgreSQL required for virtual keys.

**Key details**:
- Bedrock inference profiles need `eu.` prefix for cross-region models in eu-west-2
  (e.g. `bedrock/eu.anthropic.claude-sonnet-4-6`)
- `drop_params: true` silently drops unsupported parameters for non-Anthropic models
- Non-Anthropic models (DeepSeek, Qwen, Kimi, Nova) work with Anthropic message format
  including tool_use and SSE streaming through LiteLLM's translation layer

**Alternatives considered**: Explicit AWS credentials in config —
rejected (IAM role is simpler and more secure).

## R4: Cloudflare Tunnel via Terraform

**Decision**: Terraform manages both AWS and Cloudflare resources
in a single project.

**Rationale**: Single `terraform apply` creates EC2 instance,
tunnel, DNS record, and all networking. Tunnel token passed to
EC2 user data via SSM. `cloudflared` installed on instance, runs
as systemd service.

**Key resources**:
- `cloudflare_zero_trust_tunnel_cloudflared` — creates tunnel
- `cloudflare_zero_trust_tunnel_cloudflared_config` — ingress rules
- `cloudflare_dns_record` — CNAME to `<UUID>.cfargotunnel.com`

**Alternatives considered**: ALB ($16/month), Elastic IP + Caddy —
both rejected on cost and security (Tunnel = zero inbound ports).

## R5: EC2 Instance + PostgreSQL

**Decision**: Amazon Linux 2023 x86_64, PostgreSQL 15 on the
instance, 512MB swap, DLM for EBS snapshots.

**Rationale**: AL2023 is AWS-optimized, SSM agent pre-installed.
PostgreSQL 15 available via `dnf`. Memory budget fits in 2GB with
swap providing headroom for spikes.

**Alternatives considered**: Ubuntu 24.04 — viable but AL2023
better integrated. RDS — rejected ($12+/month).

## R6: Terraform Remote State

**Decision**: S3 backend with DynamoDB locking.

**Rationale**: GitHub Actions needs shared access to Terraform state.
Local state can't work across CI runners. S3 is the standard
Terraform backend for AWS, costs pennies/month, supports locking.

**Bootstrap** (manual one-time, before `terraform init -migrate-state`):
```bash
aws s3api create-bucket --bucket rockport-tfstate --region eu-west-2 \
  --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api put-bucket-versioning --bucket rockport-tfstate \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name rockport-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region eu-west-2
```

**Alternatives considered**:
- Terraform Cloud — adds external dependency, overkill
- Commit state to git — insecure (state contains sensitive outputs)
- S3 without locking — risks corruption from concurrent CI runs

## R7: GitHub Actions CI/CD

**Decision**: Two workflows — validate (PR) and deploy (merge to main).

**Rationale**: Validate runs on every PR: `terraform fmt -check`,
`terraform validate`, `shellcheck`. Deploy runs on merge to main:
`terraform apply -auto-approve`, then smoke tests. Separation gives
fast PR feedback while deploys only happen on main.

**Secrets required**:
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_ACCOUNT_ID`

**Alternatives considered**:
- Manual dispatch only — defeats automation purpose
- Atlantis — massive overkill for single-project Terraform
