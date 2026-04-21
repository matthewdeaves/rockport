# Rockport

OpenAI-compatible LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing any application to Bedrock models — chat, image generation, and video generation. Built for Claude Code but works with any OpenAI SDK client.

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
terraform/.build/       # Lambda zip artifacts (gitignored)
terraform/lambda/       # Lambda function source code (idle_shutdown.py)
terraform/main.tf       # EC2 instance, security group, IAM role/policies, user_data
terraform/variables.tf  # Input variables (region, instance type, cloudflared version, etc.)
terraform/outputs.tf    # Terraform outputs (instance ID, tunnel URL, region, video buckets, SSM command)
terraform/providers.tf  # AWS + Cloudflare provider configuration
terraform/versions.tf   # Required provider versions and backend config
terraform/moved.tf      # Moved blocks template for safe resource renames
terraform/tunnel.tf     # Cloudflare Tunnel ingress rules (path→port routing)
terraform/waf.tf        # Cloudflare WAF path allowlist
terraform/access.tf     # Cloudflare Access application + service token (edge pre-auth)
terraform/s3.tf         # S3 buckets for artifacts + video output (us-east-1 + us-west-2)
terraform/idle.tf       # Lambda-based idle shutdown + failure alarm
terraform/monitoring.tf # Budget alarms (Bedrock daily, monthly total), auto-recovery
terraform/snapshots.tf  # EBS snapshot lifecycle (DLM policy)
terraform/cloudtrail.tf # CloudTrail management event logging (S3 bucket + trail)
terraform/guardrails.tf # Optional Bedrock Guardrail (behind enable_guardrails variable toggle)
terraform/deployer-policies/ # 3 IAM policy JSONs (compute, iam-ssm, monitoring-storage)
terraform/rockport-admin-policy.json # Bootstrap IAM policy for admin user
terraform/terraform.tfvars.example   # Example tfvars with all variables (required + optional defaults)
terraform/.env.example               # Example .env (Cloudflare API token placeholder)
config/                 # LiteLLM config, systemd units, PostgreSQL tuning
  litellm-config.yaml   #   Model definitions, budget, rate limits
  litellm.service       #   Systemd unit for LiteLLM proxy
  cloudflared.service   #   Systemd unit for Cloudflare Tunnel
  rockport-video.service #  Systemd unit for video generation sidecar
  postgresql-tuning.conf #  PostgreSQL memory tuning for t3.small
sidecar/                # Video + image services sidecar (FastAPI on port 4001)
  video_api.py          #   Video endpoints, auth, validation, Bedrock client
  image_api.py          #   Nova Canvas image endpoints (variations, background-removal, outpaint)
  image_resize.py       #   Auto-resize for Nova Reel (scale, crop-center/top/bottom, fit to 1280x720)
  prompt_validation.py  #   Nova Reel prompt validation (negation, camera placement)
  db.py                 #   PostgreSQL job tracking, spend logging
  requirements.txt      #   Python dependencies for sidecar
  requirements.lock     #   Hashed lock file (pip-compile --generate-hashes)
scripts/bootstrap.sh    # EC2 user_data — installs PostgreSQL, LiteLLM, cloudflared, video sidecar
scripts/rockport.sh     # Admin CLI (init, keys, status, spend, logs, deploy, start/stop)
scripts/setup.sh        # Install dev tools (AWS CLI, Terraform, shellcheck, trivy, etc.)
docs/                   # Architecture diagrams
  rockport_architecture_overview.svg  # System architecture overview
  rockport_request_dataflow.svg       # Request/response flow swimlane
  future-ideas.md         # Future enhancement ideas
pentest/                # Security testing toolkit
  pentest.sh            #   Main CLI orchestrator (run/list/modules/report)
  install.sh            #   Tool installer (nmap, nuclei, ffuf, testssl.sh)
  targets/              #   Target configuration YAML files
    rockport.yaml       #   Complete Rockport attack surface definition
  scripts/              #   13 module scripts (one per security domain)
  reports/              #   Scan output (gitignored)
  tools/                #   Installed tool binaries (gitignored)
tests/smoke-test.sh     # Post-deploy verification
.github/workflows/      # CI/CD — validate (fmt, lint, security scan) + deploy (plan/apply/smoke)
.checkov.yaml           # Checkov skip list with justifications
.gitleaks.toml          # Gitleaks secret scanning config (allowlists)
.trivyignore            # Trivy IaC scan skip list
.githooks/pre-commit    # Local pre-commit hook
requirements-ci.txt     # CI-only Python dependencies (pip-audit)
```

## Key Commands

```bash
./scripts/rockport.sh init          # Interactive setup — creates tfvars + SSM master key
./scripts/rockport.sh deploy        # terraform init + apply
./scripts/rockport.sh destroy       # terraform destroy (confirms, cleans up SSM params)
./scripts/rockport.sh status        # Health + model list
./scripts/rockport.sh models        # List available models
./scripts/rockport.sh start         # Start a stopped instance
./scripts/rockport.sh stop          # Stop the instance
./scripts/rockport.sh upgrade       # Restart LiteLLM + video sidecar via SSM
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
- Claude Code sends old model IDs (e.g. `claude-sonnet-4-5-20250929`) and the new runtime identifier `claude-opus-4-7[1m]`; aliases in litellm-config.yaml map these to the latest Bedrock versions
- Chat models: Claude (Opus 4.7 with 1M context, Opus/Sonnet 4.6, Haiku 4.5), DeepSeek v3.2, Qwen3 Coder 480B, Kimi K2.5, Nova (Pro/Lite/Micro v1), Nova 2 Lite, Llama 4 (Scout/Maverick), Mistral Large 3, Ministral 8B, GPT-OSS (120B/20B)
- Claude Opus 4.7 rejects `temperature`/`top_p`/`top_k` and legacy thinking params; the global `drop_params: true` setting in litellm-config.yaml silently strips them. Cache injection is applied to every `claude-*` entry including the `[1m]` Claude Code runtime alias
- Llama 4 models use `us.` cross-region inference profiles (US-only); Nova 2 Lite uses `us.` cross-region (EU profiles not available); Mistral Large 3 is us-east-1 direct (not available in EU); Ministral 8B and GPT-OSS are direct in eu-west-2
- Bedrock inference profiles need `eu.` prefix for cross-region models; IAM policy must cover ALL EU regions (the inference profile can route to any) + all 4 US regions (us-east-1, us-east-2, us-west-1, us-west-2) for Stability AI `us.` inference profiles + image/video models + Llama 4 `us.` models
- Prompt caching: automatic via LiteLLM — `cache_control` blocks translate to Bedrock `cachePoint`. Supported on Claude and Nova 2 Lite. `cache_control_injection_points` configured for non-cache-aware clients
- Extended thinking: `reasoning_effort` supported for Claude 4.6, Nova 2 Lite, and GPT-OSS. Unsupported models silently drop the parameter
- Bedrock Guardrails: optional content filtering via `terraform/guardrails.tf` (behind `enable_guardrails` variable, default false). Terraform creates the guardrail resource; LiteLLM's guardrail config references it by ID. Supports `pre_call` (cheapest, blocks before LLM), `during_call` (parallel), `post_call` modes. PII masking via `mask_request_content`/`mask_response_content`. IAM `bedrock:ApplyGuardrail` permission added conditionally
- The EC2 instance needs a public IP for outbound internet (SSM, Bedrock, pip) — the default VPC has no NAT gateway. The SG has zero inbound rules so the public IP is not directly reachable
- Image generation models: Nova Canvas (us-east-1), Titan Image v2 (us-west-2), SD3.5 Large (us-west-2), Stable Image Ultra (us-west-2), Stable Image Core (us-west-2) — routed via per-model `aws_region_name` in litellm-config.yaml
- Image dimensions via OpenAI `size` param: Nova Canvas requires divisible by 16 (320–4096); Titan v2 uses preset sizes (256–1408); SD3.5 Large ignores `size` (fixed 1024x1024, returns JPEG not PNG)
- Image-to-image: use `/v1/images/generations` with `textToImageParams.conditionImage` (Nova Canvas) — NOT `/v1/images/edits` which is the Stability AI edit endpoint
- Cloudflare blocks requests with Python's default `Python-urllib` user-agent (403) — OpenAI SDK and curl work fine
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks both NetworkIn and CPUUtilization — instance is only stopped when both are below threshold). A CloudWatch alarm fires if the idle-stop Lambda itself fails consecutively
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
- The admin CLI requires `aws`, `terraform`, and `jq` — run `./scripts/setup.sh` to install all tools (also installs session-manager-plugin, gh, shellcheck, trivy, checkov, gitleaks, pip-audit)
- Three SSM parameters are managed: `/rockport/master-key` (by init), `/rockport/tunnel-token` (by Terraform), `/rockport/db-password` (by bootstrap)
- CI/CD uses GitHub OIDC for AWS authentication — set the `AWS_ROLE_ARN` secret in GitHub to the IAM role ARN
- The LiteLLM admin UI is intentionally disabled (`disable_admin_ui: true`) — all admin is via the CLI
- Swagger/ReDoc docs disabled via `NO_DOCS=True` / `NO_REDOC=True` in the LiteLLM env file
- Cloudflare Access (`terraform/access.tf`) requires a service token for all requests — `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers must be present or Cloudflare returns 403 before traffic reaches the tunnel. Token values are Terraform outputs (sensitive). To rotate: create a new service token in Terraform, update all clients, then remove the old one
- Cloudflare WAF allowlist (`terraform/waf.tf`) is host-scoped to the Rockport subdomain only (does not affect other apps on the zone). Blocks all paths except those needed by Claude Code, image generation (`/v1/images/generations`), image services (`/v1/images/*` for sidecar + LiteLLM edits), video generation (`/v1/videos/*`), and the admin CLI
- `setup-claude` creates keys restricted to Anthropic models only; `key create` without `--claude-only` grants access to all models including image generation. The Claude-only allowlist is derived at invocation time from every `- model_name: claude-*` entry in `config/litellm-config.yaml`; adding a new Claude model picks it up automatically. The CLI fails hard if the config is missing or contains zero Claude entries
- Stability AI image models (SD3.5 Large, Stable Image Ultra, Stable Image Core, all 13 stability-* edit models) and Luma Ray2 need a one-time Marketplace subscription — invoke once in the Bedrock playground to activate
- `deploy` auto-creates the SSM master key if missing, so `init` is not a strict prerequisite
- The Cloudflare API token (in `terraform/.env`, gitignored) needs Zone DNS Edit, Zone WAF Edit, Account Cloudflare Tunnel Edit, and Account Zero Trust Edit permissions
- Deployer IAM is split into 3 policies under `terraform/deployer-policies/` (compute, iam-ssm, monitoring-storage) to stay under the 6144-byte per-policy limit while keeping all actions explicit (no wildcards). EC2/SSM mutating actions scoped to `aws:ResourceTag/Project=rockport`. An explicit Deny in iam-ssm.json blocks `AttachRolePolicy`/`DetachRolePolicy` for any policy ARN not matching `Rockport*`, `rockport*`, `AmazonSSMManagedInstanceCore`, or `service-role/AWSDataLifecycleManagerServiceRole`, preventing privilege escalation via the deployer role
- Admin IAM policy (`terraform/rockport-admin-policy.json`): `init` auto-creates and attaches it to the calling user. If the calling user lacks `iam:CreatePolicy` (e.g. a non-admin IAM user), init prints instructions to create it manually via the AWS console first. On subsequent runs, `init` updates the policy in place.
- HSTS and "Always Use HTTPS" are enabled in Cloudflare (not managed by Terraform)
- Video generation: multi-model sidecar on port 4001 supporting Nova Reel v1.1 (us-east-1, 1280x720, 6-120s, $0.08/s) and Luma Ray2 (us-west-2, 540p/720p, 5s/9s, $0.75-1.50/s). Model selected via `model` field, defaults to `nova-reel`
- Video sidecar authenticates via LiteLLM's `/key/info` endpoint; writes spend to `LiteLLM_SpendLogs` + `LiteLLM_VerificationToken` for unified tracking
- Video output stored in per-region S3 buckets (`rockport-video-{account}-us-east-1` for Nova Reel, `rockport-video-{account}-us-west-2` for Ray2) with 7-day lifecycle; presigned URLs expire after 1 hour. Bedrock async invoke requires same-region S3 bucket
- Cloudflare Tunnel routes `/v1/videos*` and `/v1/images/*` (except `/v1/images/generations*` and `/v1/images/edits*`) to `http://localhost:4001`; `/v1/images/edits*` routes to LiteLLM (:4000) for Stability AI image edit operations; all else to `:4000` — managed in `terraform/tunnel.tf`
- Video sidecar MemoryMax is 256MB; LiteLLM reduced to 1280MB to fit on t3.small (2GB + 512MB swap)
- Single-shot (one prompt, 6-120s), multi-shot (2-20 per-shot prompts, 6s each), and multi-shot-automated (single prompt, 12-120s, model determines shot breakdown) modes supported
- Image-to-video: Nova Reel single-shot with image is fixed at 6 seconds (Bedrock TEXT_VIDEO constraint); multi-shot uses `MULTI_SHOT_MANUAL` taskType with `multiShotManualParams.shots`
- Nova Reel image requirements: exactly 1280x720, PNG or JPEG, no transparent pixels (opaque alpha channels are automatically stripped), max 10MB, submitted as data URIs. Bedrock format: `{format: "png"|"jpeg", source: {bytes: "<raw-base64>"}}`
- Ray2 image requirements: 512x512 to 4096x4096, PNG or JPEG, max 25MB, data URIs. Bedrock format: `keyframes.frame0/frame1` with `{type: "image", source: {type: "base64", media_type, data}}`. Supports start + optional end frame
- Ray2 extra params: `aspect_ratio` (7 options), `resolution` (540p/720p), `loop` (bool). No multi-shot, no seed
- Per-key concurrent job limit defaults to 3 (configurable via `VIDEO_MAX_CONCURRENT_JOBS` env var)
- Video sidecar concurrent job limit enforced atomically via `pg_advisory_xact_lock(hashtext(api_key_hash))` — count and insert happen in a single transaction, preventing TOCTOU races. Different API keys use different lock IDs so they don't block each other
- Video job status flow: `pending` (DB slot reserved, Bedrock not yet called) → `in_progress` (Bedrock invocation started, ARN set) → `completed`/`failed`. The DB slot is reserved BEFORE calling Bedrock to prevent ghost jobs
- Sidecar body size limit: 40MB max request body enforced via raw ASGI middleware (HTTP 413). Protects 256MB MemoryMax from oversized payloads
- CloudTrail: management events logged to `rockport-cloudtrail-{account}` S3 bucket with 90-day lifecycle, DenyNonSSL bucket policy. Defined in `terraform/cloudtrail.tf`
- Error sanitization: all Bedrock errors in video_api.py and image_api.py are logged server-side with reference UUIDs; clients receive generic messages with reference IDs for correlation. Bedrock ThrottlingException errors return HTTP 429 with `Retry-After: 5` header (not 502) so clients can implement backoff
- Video endpoints enforce --claude-only key restriction (HTTP 403), consistent with image API behavior
- Sidecar pip dependencies installed with `--require-hashes` from `sidecar/requirements.lock` for supply chain integrity
- Cloudflared binary verified via pinned SHA256 hash during bootstrap (`cloudflared_sha256` variable — cloudflared releases don't include per-file checksum files)
- Deploy artifacts verified via SHA256 checksum in bootstrap (generated during `rockport.sh deploy`/`config push`)
- Instance IAM: Bedrock `foundation-model/*` wildcard replaced with specific model family patterns; SSM PutParameter scoped to `/rockport/db-password` only
- Deployer IAM: SSM documents scoped to `AWS-RunShellScript` and `AWS-StartInteractiveCommand` only
- State bucket gets DenyNonSSL policy on creation via `rockport.sh init`
- Bootstrap runs `prisma migrate deploy` before LiteLLM starts — avoids slow per-migration baseline resolve on first boot. Full bootstrap completes in ~3 minutes
- Nova Canvas sidecar endpoints on (:4001): `/v1/images/variations`, `/v1/images/background-removal`, `/v1/images/outpaint`. All enforce auth, budgets, and block --claude-only keys
- Video sidecar `/v1/videos/health` requires a valid Bearer token (spec 016 FR-007) — anonymous callers get HTTP 401, preventing enumeration of per-region Bedrock availability

## Bedrock retirement calendar

Known upstream end-of-life dates for models currently in `config/litellm-config.yaml`. Plan replacements before each date.

| Model ID | Rockport alias | EOL | Notes |
|---|---|---|---|
| `amazon.titan-image-generator-v2:0` | `titan-image-v2` | **2026-06-30** | Kept by operator choice; replacement plan required ≤ 10 weeks |
| `amazon.nova-canvas-v1:0` | `nova-canvas` (+ sidecar endpoints) | **2026-09-30** | No announced direct successor; likely migration to Stability Core/Ultra |
| `amazon.nova-reel-v1:1` | Nova Reel video pipeline | **2026-09-30** | Luma Ray2 remains; no Ray3 on Bedrock yet |

## Active Technologies
- Terraform 1.14 (AWS provider 6.41, Cloudflare provider ~> 5.0)
- LiteLLM proxy 1.83.7 (exact pin) on Amazon Linux 2023
- Python 3.11 + FastAPI — sidecar (port 4001)
- PostgreSQL 15 — LiteLLM spend/keys + video job tracking
- S3 — state + video output
- Bash — CLI, bootstrap, smoke tests, pentest toolkit
- CloudTrail — audit logging
- Cloudflare Tunnel + Access + WAF — ingress and pre-auth

## Pentest Toolkit
- 13-module security testing suite in `pentest/` — tests WAF allowlist, CF-Access tokens, API key auth, tunnel routing, sidecar endpoints, infrastructure security, supply chain integrity
- Run a full scan: `./pentest/pentest.sh run rockport` or use `/pentest` skill
- Run single module: `./pentest/pentest.sh run rockport --module waf`
- List modules: `./pentest/pentest.sh modules`
- View latest report: `./pentest/pentest.sh report rockport`
- Install optional tools (nmap, nuclei, ffuf, testssl.sh): `./pentest/install.sh`
- Target config: `pentest/targets/rockport.yaml` — complete attack surface definition (endpoints, WAF paths, tunnel routes, known risks, false positives)
- Reports: `pentest/reports/rockport/<timestamp>/` — `results.json` (structured), `SUMMARY.md` (human-readable), `run.log` (concatenated output)
- Modules: recon, headers, tls, waf, access, auth, api, injection (destructive), tunnel, sidecar, infra, supply-chain, paths
- Auth bootstrap: creates temp API key ($0.50 budget), reads CF-Access headers from terraform output, auto-revokes key on completion
- All scripts use explicit error handling (Constitution VI) — no `set -euo pipefail`
- Cost control: scan costs under $0.25 (uses claude-haiku-4-5-20251001 with max_tokens:1 for auth tests)
- Skills: `/pentest` (run scans), `/pentest-review` (triage results), `/pentest-align` (detect drift between pentest suite and codebase)
- Quality hooks: PreToolUse `pentest-bash-gotchas.sh` checks for common bash pitfalls in pentest scripts

## Recent Changes
- **016-security-claude-4-7-upgrade**: LiteLLM 1.82.6 → 1.83.7 (patches 6 advisories including a SQL-injection on the API-key auth path). Added Claude Opus 4.7 via `eu.anthropic.claude-opus-4-7` plus the literal `claude-opus-4-7[1m]` Claude Code runtime alias, both with cache injection. WAF rules now use `var.domain` (no hardcoded hostname). `--claude-only` key allowlist derived at invocation time from `config/litellm-config.yaml`. `/v1/videos/health` now requires Bearer auth (previously anonymous). psycopg2-binary 2.9.11 → 2.9.12. Bedrock retirement calendar documented for Titan Image v2 (2026-06-30), Nova Canvas v1 and Nova Reel v1.1 (both 2026-09-30).
- Added pentest toolkit with 13 security modules, 3 Claude Code skills (`/pentest`, `/pentest-review`, `/pentest-align`), enhanced `/rockport-ops` with security posture checks, and quality hooks for pentest scripts
- Added 9 new Bedrock chat models (Qwen3 Coder 480B, Kimi K2.5, Llama 4 Scout/Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, GPT-OSS 120B/20B), prompt caching, extended thinking, and optional Bedrock Guardrails (`deploy --guardrails`)
