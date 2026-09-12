# Rockport

OpenAI-compatible LiteLLM proxy on EC2 behind Cloudflare Tunnel, routing any application to Bedrock models — chat, image generation, and video generation. Built for Claude Code but works with any OpenAI SDK client.

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, snapshots, monitoring, idle shutdown)
terraform/.build/       # Lambda zip artifacts (gitignored)
terraform/lambda/       # Lambda function source code (idle_shutdown.py)
terraform/main.tf       # EC2 instance, security group, IAM role/policies, user_data
terraform/variables.tf  # Input variables (region, instance type, cloudflared version, etc.)
terraform/outputs.tf    # Terraform outputs (instance ID, tunnel URL, region, video bucket, SSM command)
terraform/providers.tf  # AWS + Cloudflare provider configuration
terraform/versions.tf   # Required provider versions and backend config
terraform/moved.tf      # Moved blocks template for safe resource renames
terraform/tunnel.tf     # Cloudflare Tunnel ingress rules (path→port routing)
terraform/waf.tf        # Cloudflare WAF path allowlist
terraform/access.tf     # Cloudflare Access application + service token (edge pre-auth)
terraform/s3.tf         # S3 buckets for artifacts + video output (us-west-2)
terraform/idle.tf       # Lambda-based idle shutdown + failure alarm
terraform/monitoring.tf # Budget alarms (Bedrock daily, monthly total), auto-recovery
terraform/snapshots.tf  # EBS snapshot lifecycle (DLM policy)
terraform/cloudtrail.tf # CloudTrail management event logging (S3 bucket + trail)
terraform/guardrails.tf # Optional Bedrock Guardrail (behind enable_guardrails variable toggle)
terraform/iam-operator-roles.tf # Operator roles (017): readonly + runtime-ops + deploy with MFA-gated trust + boundaries
terraform/deployer-policies/ # IAM policy JSONs: compute, iam-ssm, monitoring-storage, readonly, runtime-ops, assume-roles
terraform/rockport-admin-policy.json # Bootstrap IAM policy for admin user (carries IAM-mutation actions, MFA management)
terraform/terraform.tfvars.example   # Example tfvars with all variables (required + optional defaults)
terraform/.env.example               # Example .env (Cloudflare API token placeholder)
config/                 # LiteLLM config, systemd units, PostgreSQL tuning
  litellm-config.yaml   #   Model definitions, budget, rate limits
  litellm.service       #   Systemd unit for LiteLLM proxy
  cloudflared.service   #   Systemd unit for Cloudflare Tunnel
  rockport-video.service #  Systemd unit for video generation sidecar
  postgresql-tuning.conf #  PostgreSQL memory tuning for t3.small
sidecar/                # Video sidecar (FastAPI on port 4001) — Luma Ray2 only
  video_api.py          #   Video endpoints, auth, validation, Bedrock async-invoke client
  db.py                 #   PostgreSQL job tracking, spend logging
  requirements.txt      #   Python dependencies for sidecar
  requirements.lock     #   Hashed lock file (pip-compile --generate-hashes)
scripts/bootstrap.sh    # EC2 user_data — installs PostgreSQL, LiteLLM, cloudflared, video sidecar
scripts/rockport.sh     # Admin CLI dispatcher (init, deploy, destroy + sources lib/*.sh)
scripts/lib/api.sh      #   Cloudflare tunnel + CF-Access + LiteLLM HTTP helper
scripts/lib/auth.sh     #   Operator-role auth (017) + admin MFA session (018) + cmd_auth
scripts/lib/diag.sh     #   cmd_status (HTTP + EC2 health probes) + cmd_models
scripts/lib/iam.sh      #   IAM policy + deployer-user lifecycle helpers (used by init)
scripts/lib/keys.sh     #   Virtual API key CRUD + Claude-only allowlist + setup-claude
scripts/lib/spend.sh    #   Spend reporting + live monitor
scripts/lib/ssm.sh      #   SSM helpers + cmd_config_push/upgrade/logs/start/stop
scripts/lib/state.sh    #   Master-key SSM + Terraform state-bucket helpers
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
tests/auth-flow-test.sh # Sandbox tests for the 017 CLI auth helpers (assume_role, ensure_session_valid_for_role, SUBCOMMAND_ROLE)
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
./scripts/rockport.sh auth          # 017: assume an operator role via MFA [--role readonly|runtime-ops|deploy]
./scripts/rockport.sh auth status   # 017: show cached operator-role sessions and time remaining
./scripts/rockport.sh deploy        # terraform init + apply
./scripts/rockport.sh destroy       # terraform destroy (confirms, cleans up SSM params)
./scripts/rockport.sh status        # Health + model list (readonly role; --instance escalates to runtime-ops for in-VM stats)
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
- Claude Code sends old model IDs (e.g. `claude-sonnet-4-5-20250929`) and `[1m]`-suffixed runtime identifiers (`claude-opus-5[1m]`, `claude-opus-4-7[1m]`); aliases in litellm-config.yaml map these to Bedrock `eu.` inference profiles. `[1m]` aliases exist for Opus 5, Sonnet 5, Opus 4.8 and Opus 4.7
- Chat models: Claude (Opus 5, Sonnet 5, Opus 4.8, Opus 4.7, Opus/Sonnet 4.6 — all 1M context — and Haiku 4.5), DeepSeek v3.2, Qwen3 Coder 480B, Kimi K2.5, Nova (Pro/Lite/Micro v1), Nova 2 Lite, Llama 4 (Scout/Maverick), Mistral Large 3, Ministral 8B, GPT-OSS (120B/20B)
- Claude 4.6+ models reject `temperature`/`top_p`/`top_k` and legacy `budget_tokens` thinking params; the global `drop_params: true` setting in litellm-config.yaml silently strips them. Cache injection is applied to every `claude-*` entry including the `[1m]` Claude Code runtime aliases
- Cost-first defaults: `setup-claude` writes `"model": "claude-sonnet-5"` into the generated Claude Code settings (users pick Opus per session with `/model`); video defaults to 5s/540p; image health probes use the smallest size. Bigger is always opt-in, never the default
- Llama 4 models use `us.` cross-region inference profiles (US-only); Nova 2 Lite uses `us.` cross-region (EU profiles not available); Mistral Large 3 is us-east-1 direct (not available in EU); Ministral 8B and GPT-OSS are direct in eu-west-2
- Bedrock inference profiles need `eu.` prefix for cross-region models; IAM policy must cover ALL EU regions (the inference profile can route to any) + all 4 US regions (us-east-1, us-east-2, us-west-1, us-west-2) for Stability AI `us.` inference profiles + image/video models + Llama 4 `us.` models
- Prompt caching: automatic via LiteLLM — `cache_control` blocks translate to Bedrock `cachePoint`. Supported on Claude and Nova 2 Lite. `cache_control_injection_points` configured for non-cache-aware clients
- Extended thinking: `reasoning_effort` supported for Claude 4.6+, Nova 2 Lite, and GPT-OSS. Unsupported models silently drop the parameter
- Bedrock Guardrails: optional content filtering via `terraform/guardrails.tf` (behind `enable_guardrails` variable, default false). Terraform creates the guardrail resource; LiteLLM's guardrail config references it by ID. Supports `pre_call` (cheapest, blocks before LLM), `during_call` (parallel), `post_call` modes. PII masking via `mask_request_content`/`mask_response_content`. IAM `bedrock:ApplyGuardrail` permission added conditionally
- The EC2 instance needs a public IP for outbound internet (SSM, Bedrock, pip) — the default VPC has no NAT gateway. The SG has zero inbound rules so the public IP is not directly reachable
- Image generation models: Stable Image Core, Stable Image Ultra, SD3.5 Large (all us-west-2) — routed via per-model `aws_region_name` in litellm-config.yaml. Nova Canvas (EOL 2026-09-30) and Titan Image v2 (EOL 2026-06-30) were removed
- Image dimensions via OpenAI `size` param: SD3.5 Large ignores `size` (fixed 1024x1024, returns JPEG not PNG); Stability Core/Ultra are aspect-ratio based
- Image-to-image: Stable Image Ultra via `/v1/images/generations` with `mode: "image-to-image"`, or the Stability AI edit models via `/v1/images/edits`
- Cloudflare blocks requests with Python's default `Python-urllib` user-agent (403) — OpenAI SDK and curl work fine
- `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) is the env var for Claude Code virtual keys
- Instance auto-stops after 30min of inactivity by default (Lambda checks both NetworkIn and CPUUtilization — instance is only stopped when both are below threshold). A CloudWatch alarm fires if the idle-stop Lambda itself fails consecutively
- Region is read from `terraform.tfvars` by rockport.sh — no hardcoded region in the CLI
- cloudflared version is pinned via `cloudflared_version` variable for stability
- The admin CLI requires `aws`, `terraform`, and `jq` — run `./scripts/setup.sh` to install all tools (also installs session-manager-plugin, gh, shellcheck, trivy, checkov, gitleaks, pip-audit). Scripts use `#!/usr/bin/env bash` because `auth.sh` needs bash 4+ (`declare -A`) and macOS `/bin/bash` is 3.2. `auth.sh` parses STS expiry timestamps with `_iso_to_epoch`, which works on both GNU and BSD `date`
- Three SSM parameters are managed: `/rockport/master-key` (by init), `/rockport/tunnel-token` (by Terraform), `/rockport/db-password` (by bootstrap)
- CI/CD uses GitHub OIDC for AWS authentication — set the `AWS_ROLE_ARN` secret in GitHub to the IAM role ARN
- The LiteLLM admin UI is intentionally disabled (`disable_admin_ui: true`) — all admin is via the CLI
- Swagger/ReDoc docs disabled via `NO_DOCS=True` / `NO_REDOC=True` in the LiteLLM env file
- Cloudflare Access (`terraform/access.tf`) requires a service token for all requests — `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers must be present or Cloudflare returns 403 before traffic reaches the tunnel. Token values are Terraform outputs (sensitive). To rotate: create a new service token in Terraform, update all clients, then remove the old one
- Cloudflare WAF allowlist (`terraform/waf.tf`) is host-scoped to the Rockport subdomain only (does not affect other apps on the zone). Blocks all paths except those needed by Claude Code, image generation (`/v1/images/generations`), image edits (`/v1/images/edits`), video generation (`/v1/videos/*`), and the admin CLI. Other `/v1/images/*` paths (the retired Nova Canvas sidecar endpoints) are blocked at the edge
- `setup-claude` creates keys restricted to Anthropic models only; `key create` without `--claude-only` grants access to all models including image generation. The Claude-only allowlist is derived at invocation time from every `- model_name: claude-*` entry in `config/litellm-config.yaml`; adding a new Claude model picks it up automatically. The CLI fails hard if the config is missing or contains zero Claude entries
- Stability AI image models (SD3.5 Large, Stable Image Ultra, Stable Image Core, all 13 stability-* edit models) and Luma Ray2 need a one-time Marketplace subscription — invoke once in the Bedrock playground to activate
- `deploy` auto-creates the SSM master key if missing, so `init` is not a strict prerequisite
- The Cloudflare API token (in `terraform/.env`, gitignored) needs Zone DNS Edit, Zone WAF Edit, Account Cloudflare Tunnel Edit, and Account Zero Trust Edit permissions
- Deployer IAM is split into 3 policies under `terraform/deployer-policies/` (compute, iam-ssm, monitoring-storage) to stay under the 6144-byte per-policy limit while keeping all actions explicit (no wildcards). EC2/SSM mutating actions scoped to `aws:ResourceTag/Project=rockport`. An explicit Deny in iam-ssm.json (017) blocks `AttachRolePolicy`/`DetachRolePolicy` ONLY when the modified role is a Rockport role (`arn:aws:iam::*:role/rockport*` or `dlm-lifecycle-*`); attaching anything to non-Rockport roles is unaffected — this lets Appserver share the AWS account without IAM collisions. Belt-and-braces `DenyAttachToInstanceRole` blocks any policy attachment to `rockport-instance-role` regardless of policy ARN.
- 017 operator roles: `rockport.sh` maps every subcommand to one of three roles via `SUBCOMMAND_ROLE`. `rockport-readonly-role` (no SendCommand, no IAM) backs `status`/`models`/`spend`/`monitor`/`key`/`setup-claude`. `rockport-runtime-ops-role` adds SSM SendCommand on the tagged instance and S3 write to artifacts/video buckets — backs `config push`/`upgrade`/`start`/`stop`/`logs`/`status --instance`. `rockport-deploy-role` carries the three legacy deployer policies; the boundary explicitly denies `iam:CreatePolicy*`/`CreateUser`/`AttachUserPolicy`/`CreateAccessKey` so a compromised deploy session can't rewrite its own policies or mint access keys (Finding B from Appserver 003). Trust policies require MFA + age<3600; `MaxSessionDuration=3600`.
- 017 auth flow: `rockport.sh auth [--role <name>]` prompts for TOTP and caches creds under `rockport-<role>` profile. `MFA_SERIAL_NUMBER` lives in `terraform/.env` (gitignored). Sessions reuse silently while valid (>5 min remaining). `rockport.sh auth status` lists cached sessions. `ROCKPORT_AUTH_DISABLED=1` is the bootstrap escape hatch for the first-ever `init` on a fresh account; otherwise every AWS-touching subcommand requires an MFA-derived STS session (the legacy long-lived `rockport` profile is no longer auto-used).
- Admin IAM policy (`terraform/rockport-admin-policy.json`): `init` auto-creates and attaches it to the calling user. If the calling user lacks `iam:CreatePolicy` (e.g. a non-admin IAM user), init prints instructions to create it manually via the AWS console first. On subsequent runs, `init` updates the policy in place. After 017, `RockportAdmin` carries the IAM-policy and IAM-user mutation actions (CreatePolicy/CreatePolicyVersion/CreateUser/AttachUserPolicy/CreateAccessKey/...) plus full MFA-management actions (Enable/Deactivate/Resync/CreateVirtualMFADevice/...) so the admin can recover a lost MFA device on `rockport-deployer`. After 018, `RockportAdmin` carries a `DenyAllWithoutMFA` statement (Effect:Deny, NotAction:[GetUser, ChangePassword, MFA-management, sts:GetSessionToken, sts:GetCallerIdentity, ListAccessKeys], Resource:*, Condition: aws:MultiFactorAuthPresent=false). A leaked rockport-admin access key is therefore useless without the second factor — every meaningful action requires an MFA-derived session minted via `sts:GetSessionToken`. `rockport.sh init` mints that session via the new `admin_mfa_session()` helper, which reads `ROCKPORT_ADMIN_MFA_SERIAL` from `terraform/.env` and caches creds under the `rockport-admin-mfa` profile.
- HSTS and "Always Use HTTPS" are enabled in Cloudflare (not managed by Terraform)
- Video generation: sidecar on port 4001 driving Luma Ray2 (us-west-2, 540p/720p, 5s/9s, $0.75-1.50/s). `model` field defaults to `luma-ray2` (the only model); defaults are the cheapest valid options (5s, 540p, 16:9). Nova Reel was removed ahead of its 2026-09-30 EOL. LiteLLM's `/v1/videos` endpoint does not support Bedrock (OpenAI/Azure/Gemini/Vertex/RunwayML only as of 1.100), so the sidecar stays
- Video sidecar authenticates via LiteLLM's `/key/info` endpoint; writes spend to `LiteLLM_SpendLogs` + `LiteLLM_VerificationToken` for unified tracking
- Video output stored in `rockport-video-{account}-us-west-2` with 7-day lifecycle; presigned URLs expire after 1 hour. Bedrock async invoke requires a same-region S3 bucket. The old us-east-1 bucket is gone; the `aws.us_east_1` provider alias in `s3.tf` is kept only so Terraform can destroy it from existing state and can be deleted after that apply
- Cloudflare Tunnel routes `/v1/videos*` to `http://localhost:4001`; `/v1/images/generations*` and `/v1/images/edits*` to LiteLLM (:4000); all else to `:4000` — managed in `terraform/tunnel.tf`
- Video sidecar MemoryMax is 256MB; LiteLLM reduced to 1280MB to fit on t3.small (2GB + 512MB swap)
- Ray2 image requirements: 512x512 to 4096x4096, PNG or JPEG, max 25MB, data URIs. Bedrock format: `keyframes.frame0/frame1` with `{type: "image", source: {type: "base64", media_type, data}}`. Supports start + optional end frame
- Ray2 params: `aspect_ratio` (7 options, default 16:9), `resolution` (540p default / 720p), `loop` (bool), `duration` (5 default / 9). No multi-shot, no seed. `end_image` requires `image`
- Per-key concurrent job limit defaults to 3 (configurable via `VIDEO_MAX_CONCURRENT_JOBS` env var)
- Video sidecar concurrent job limit enforced atomically via `pg_advisory_xact_lock(hashtext(api_key_hash))` — count and insert happen in a single transaction, preventing TOCTOU races. Different API keys use different lock IDs so they don't block each other
- Video job status flow: `pending` (DB slot reserved, Bedrock not yet called) → `in_progress` (Bedrock invocation started, ARN set) → `completed`/`failed`. The DB slot is reserved BEFORE calling Bedrock to prevent ghost jobs
- Sidecar body size limit: 40MB max request body enforced via raw ASGI middleware (HTTP 413). Protects 256MB MemoryMax from oversized payloads
- CloudTrail: management events logged to `rockport-cloudtrail-{account}` S3 bucket with 90-day lifecycle, DenyNonSSL bucket policy. Defined in `terraform/cloudtrail.tf`
- Error sanitization: all Bedrock errors in video_api.py are logged server-side with reference UUIDs; clients receive generic messages with reference IDs for correlation. Bedrock ThrottlingException errors return HTTP 429 with `Retry-After: 5` header (not 502) so clients can implement backoff
- Video endpoints enforce --claude-only key restriction (HTTP 403)
- Sidecar pip dependencies installed with `--require-hashes` from `sidecar/requirements.lock` for supply chain integrity
- Cloudflared binary verified via pinned SHA256 hash during bootstrap (`cloudflared_sha256` variable — cloudflared releases don't include per-file checksum files)
- Deploy artifacts verified via SHA256 checksum in bootstrap (generated during `rockport.sh deploy`/`config push`)
- Instance IAM: Bedrock `foundation-model/*` wildcard replaced with specific model family patterns (`amazon.titan-*` removed with Titan Image v2; async-invoke grant is `luma.*` in us-west-2 only); SSM PutParameter scoped to `/rockport/db-password` only
- Deployer IAM: SSM documents scoped to `AWS-RunShellScript` and `AWS-StartInteractiveCommand` only
- State bucket gets DenyNonSSL policy on creation via `rockport.sh init`
- Bootstrap runs `prisma migrate deploy` before LiteLLM starts — avoids slow per-migration baseline resolve on first boot. Full bootstrap completes in ~3 minutes
- Video sidecar `/v1/videos/health` requires a valid Bearer token (spec 016 FR-007) — anonymous callers get HTTP 401, preventing enumeration of per-region Bedrock availability

## Bedrock retirement calendar

Known upstream lifecycle dates for models in `config/litellm-config.yaml` (source: AWS Bedrock model cards / model-lifecycle page). Plan replacements before each date. Nothing currently configured is in the Legacy state.

| Model | Bedrock ID | Launched | EOL no sooner than |
|---|---|---|---|
| Claude Opus 5 | `anthropic.claude-opus-5` | 2026-07-24 | 2027-07-24 |
| Claude Sonnet 5 | `anthropic.claude-sonnet-5` | 2026-06-30 | 2027-06-30 |
| Claude Opus 4.8 | `anthropic.claude-opus-4-8` | 2026-05-28 | 2027-05-28 |

Retired from this repo (2026-09-12): Titan Image v2 (EOL 2026-06-30), Nova Canvas v1 and Nova Reel v1.1 (both EOL 2026-09-30). Legacy Bedrock models are cut off for accounts after 15 days of inactivity, so these were effectively dead for an idle-stopped instance before the EOL date.

## Active Technologies
- Terraform 1.14 (AWS provider 6.41, Cloudflare provider ~> 5.0)
- LiteLLM proxy 1.100.1 (exact pin) on Amazon Linux 2023
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
- **2026-09 refresh (branch `chore/sept-2026-refresh`)**: (a) Retired Nova Canvas, Nova Reel and Titan Image v2 ahead of Bedrock EOL — deleted `sidecar/image_api.py`, `image_resize.py`, `prompt_validation.py`, the us-east-1 video bucket, the `/v1/images/*` sidecar tunnel route and the Nova/Titan IAM grants; sidecar is now Ray2-only (`video_api.py` ~half the size, no multi-shot/seed/resize). (b) Added Claude Opus 5, Sonnet 5 and Opus 4.8 via `eu.` profiles plus `[1m]` Claude Code aliases. (c) LiteLLM 1.83.7 → 1.100.1 (patches CVE-2026-35029 / CVE-2026-59822), cloudflared 2026.3.0 → 2026.9.1, sidecar deps bumped and lock regenerated (idna PYSEC-2026-215 fixed). (d) Cost-first defaults: `setup-claude` pins `claude-sonnet-5`, Ray2 defaults to 540p. (e) macOS portability: `#!/usr/bin/env bash` shebangs (bash 3.2 lacks `declare -A`), `_iso_to_epoch` replaces GNU-only `date -d` in `auth.sh` so cached MFA sessions are recognised on macOS, `auth-flow-test.sh` passes on macOS. WAF now allowlists `/v1/images/edits` explicitly (previously covered by the removed `/v1/images/` prefix).
- **021-destroy-via-admin**: `cmd_destroy` now runs under the admin role (`SUBCOMMAND_ROLE[destroy]=admin`) instead of the deploy role. Two reasons: (a) the deploy boundary explicit-denies `iam:DeletePolicy` on Resource:*, so terraform under deploy can't delete the operator-tier boundary policies it itself created (Finding-B protection); (b) terraform destroys `aws_iam_role.operator_deploy` mid-run, invalidating the deploy STS session — every call after that point returns `InvalidAccessKeyId`. Admin's session is independent of any terraform-managed role. `rockport-admin` user carries `RockportAdmin` + the three deployer policies (`Compute`, `IamSsm`, `MonitoringStorage`), so it has every permission `terraform destroy` needs without expanding the policy. `cmd_destroy` calls `admin_mfa_session` at the top.
- **020-claude-hooks**: Mirror Appserver's PreToolUse hook stack — `block-credential-reads.sh` (file pattern + live-credential-printing CLI patterns) and `block-destructive.sh` (rm -rf, dd, drop database, etc.). Adds `permissions.deny` for `Read/Edit` on `terraform/.env`, `~/.aws/credentials`, `~/.aws/config`. Belt-and-braces on top of the permissions deny: catches the cases where Claude builds the unsafe command via `cat`/`grep`/`sed`/`awk` instead of using the Read tool. Triggered by today's incident where the cwd-leaked Cloudflare API tokens — even after rotation, hooks at the tool layer prevent recurrence.
- **019-rockport-cli-split**: Split the monolithic `scripts/rockport.sh` (~2250 lines) into a slim dispatcher (~460 lines) plus 8 lib files under `scripts/lib/` (api, auth, diag, iam, keys, spend, ssm, state). Pure refactor — no behavior change. CI's shellcheck now uses `-x` to follow source directives. Cuts review surface for future changes (a single subcommand modification touches ≤300 lines instead of scrolling past 2000+).
- **018-rockport-admin-mfa**: Closes the residual gap from 017 — `rockport-admin`'s long-lived access key is no longer usable without MFA. Added `DenyAllWithoutMFA` to `terraform/rockport-admin-policy.json` (Effect:Deny, NotAction:[GetUser, ChangePassword, MFA-management, sts:GetSessionToken, sts:GetCallerIdentity, ListAccessKeys], Resource:*, Condition:`aws:MultiFactorAuthPresent=false`). `rockport.sh init` now calls `admin_mfa_session()` first — reads `ROCKPORT_ADMIN_MFA_SERIAL` from `terraform/.env`, prompts for TOTP, mints a 1-hour session via `sts:GetSessionToken`, caches it under the `rockport-admin-mfa` profile. `ROCKPORT_AUTH_DISABLED=1` still bypasses (true bootstrap on a fresh account where the policy isn't deployed yet). The admin user is shared with Appserver, so a parallel CLI update on the Appserver side is needed for `appserver.sh init` to keep working.
- **017-iam-mfa-scoping**: MFA-gated short-lived STS sessions across three operator roles (`rockport-readonly-role`, `rockport-runtime-ops-role`, `rockport-deploy-role`). Each role has a permissions boundary; trust policies require `aws:MultiFactorAuthPresent=true` and `aws:MultiFactorAuthAge<3600`; `MaxSessionDuration=3600`. CLI maps subcommands to roles via `SUBCOMMAND_ROLE`; `rockport.sh auth [--role <name>]` prompts for TOTP and caches creds under `rockport-<role>` profile. Readonly has zero `ssm:SendCommand` (Finding A from Appserver 003 — `cmd_status` falls back to HTTP probes; `status --instance` escalates to runtime-ops). Deploy role drops `iam:CreatePolicy*` / `CreateUser` / `AttachUserPolicy` / `CreateAccessKey` (Finding B — IAM mutation moves to `RockportAdmin`, admin-only). Cross-project deny in `iam-ssm.json` is now Resource-scoped to `rockport*` roles so Appserver IAM operations no longer collide. `tests/auth-flow-test.sh` runs in CI; `ROCKPORT_AUTH_DISABLED=1` is the bootstrap escape hatch.
- **016-security-claude-4-7-upgrade**: LiteLLM 1.82.6 → 1.83.7 (patches 6 advisories including a SQL-injection on the API-key auth path). Added Claude Opus 4.7 via `eu.anthropic.claude-opus-4-7` plus the literal `claude-opus-4-7[1m]` Claude Code runtime alias, both with cache injection. WAF rules now use `var.domain` (no hardcoded hostname). `--claude-only` key allowlist derived at invocation time from `config/litellm-config.yaml`. `/v1/videos/health` now requires Bearer auth (previously anonymous). psycopg2-binary 2.9.11 → 2.9.12. Bedrock retirement calendar documented for Titan Image v2 (2026-06-30), Nova Canvas v1 and Nova Reel v1.1 (both 2026-09-30).
- Added pentest toolkit with 13 security modules, 3 Claude Code skills (`/pentest`, `/pentest-review`, `/pentest-align`), enhanced `/rockport-ops` with security posture checks, and quality hooks for pentest scripts
- Added 9 new Bedrock chat models (Qwen3 Coder 480B, Kimi K2.5, Llama 4 Scout/Maverick, Nova 2 Lite, Mistral Large 3, Ministral 8B, GPT-OSS 120B/20B), prompt caching, extended thinking, and optional Bedrock Guardrails (`deploy --guardrails`)
