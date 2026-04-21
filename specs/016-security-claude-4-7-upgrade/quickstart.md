# Quickstart — verifying feature 016

## Prerequisites

- Working tree on branch `016-security-claude-4-7-upgrade` with the feature's file changes applied.
- `aws`, `terraform`, `jq`, `shellcheck` installed (via `./scripts/setup.sh`).
- AWS credentials profile `rockport` configured, or `AWS_PROFILE` exported.
- `terraform/terraform.tfvars` and `terraform/.env` populated (first-time: `./scripts/rockport.sh init`).

## 1. Local quality gates

Run these in sequence — all must pass before push:

```bash
# Terraform formatting + validation
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

# Shell lint
shellcheck scripts/*.sh tests/*.sh pentest/pentest.sh pentest/scripts/*.sh

# Python dependency audit (regenerated lock)
sed 's/ *\\$//; /^ *--hash/d' sidecar/requirements.lock > /tmp/requirements-audit.txt
pip-audit -r /tmp/requirements-audit.txt

# Secrets + IaC scans (versions pinned in CI; install locally if needed)
gitleaks detect --source . --no-banner --config .gitleaks.toml
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore terraform/
checkov -d terraform/ --config-file .checkov.yaml
```

Expected outcome: every command exits 0.

## 2. Fresh deploy from destroyed state

Given the instance was destroyed, run the full deploy:

```bash
./scripts/rockport.sh deploy
```

Observe:

- Terraform plan includes the two Opus 4.7 entries (via config push), the WAF `${var.domain}` substitution, and the LiteLLM version update.
- Bootstrap installs LiteLLM **1.83.7** on the new instance.
- `cloudflared` connects the tunnel.
- Service health converges within ~3 minutes of bootstrap.

## 3. Smoke test

```bash
./tests/smoke-test.sh
```

Expected: all assertions pass, including:

- `/v1/models` lists `claude-opus-4-7` and `claude-opus-4-7[1m]`.
- A chat completion against `claude-opus-4-7[1m]` returns a 200 with non-zero content.
- An authenticated `/v1/videos/health` returns 200 with per-model detail.
- An **un**authenticated `/v1/videos/health` returns 401 with body `{"detail":"unauthorized"}`.

## 4. Prompt-cache sanity check

Issue the same chat-completion twice against `claude-opus-4-7[1m]` with an identical system prompt (>1024 tokens to meet Bedrock's cache-floor). On the second call, `usage.cache_read_input_tokens` should be > 0.

```bash
# Example (replace KEY + URL)
curl -s -X POST "$URL/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  --data-binary @payload.json | jq '.usage'
```

## 5. Pentest

```bash
./pentest/pentest.sh run rockport
```

Expected: suite completes PASS. The `sidecar` module should report the `/v1/videos/health` endpoint correctly rejecting anonymous probes.

## 6. Claude-only key verification

```bash
# Derive allowlist from config (used internally by the CLI)
./scripts/rockport.sh key create test-claude-only --claude-only --budget 0.25

# Inspect the generated key — `models` field should match every
# model_name: claude-* line in config/litellm-config.yaml exactly.
./scripts/rockport.sh key info <generated-key>

# Clean up
./scripts/rockport.sh key revoke <generated-key>
```

## 7. WAF domain portability (static check)

```bash
# Confirm no hardcoded hostname literals remain in waf.tf
grep -c 'llm.matthewdeaves.com' terraform/waf.tf
# Expected: 0
grep -c '${var.domain}' terraform/waf.tf
# Expected: 3
```

## Failure / rollback

If step 2, 3, or 5 fails:

```bash
git revert <merge-sha>      # restore previous LiteLLM + config state
./scripts/rockport.sh upgrade   # redeploy reverted artifacts
```

The reverted proxy reverts to LiteLLM 1.82.6; no database action is required (additive migrations only in this patch window).
