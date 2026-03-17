# Rockport Constitution

## Core Principles

### I. Cost Minimization

Infrastructure cost (excluding Bedrock token charges) MUST stay
under £100/month, target under £15/month. One operator, ~8
hours/day Claude Code usage, handful of accounts.

- EC2 `t3.small` on-demand (2GB RAM) MUST be the compute
  target. ARM/Graviton (t4g) is incompatible with LiteLLM's
  Prisma client. 2GB is the minimum for LiteLLM proxy +
  PostgreSQL on the same instance.
- No load balancers (ALB, NLB).
- No NAT Gateways. Public subnet with security group.
- No managed databases (RDS, Aurora, ElastiCache). PostgreSQL
  runs on the instance itself.
- No Elastic IP. Cloudflare Tunnel eliminates the need for a
  public IP (saves ~£3.65/month).
- No Route 53. DNS is on Cloudflare (existing account, free).
- No CloudWatch Logs or CloudWatch agent. Logs live on the
  instance via journald, accessed through SSM Session Manager.
- Infrastructure MUST be IaC (Terraform). Deploy,
  upgrade, and teardown MUST each be a single command.

### II. Security

No compliance, PII, or data-retention requirements. Security
exists to prevent unauthorized Bedrock spend.

- **TLS**: Cloudflare handles all TLS termination. Traffic
  from users hits `llm.matthewdeaves.com` (or similar
  subdomain) over HTTPS. Cloudflare routes it through a
  Cloudflare Tunnel to the instance. No TLS certs on the
  instance, no Caddy, no certbot.
- **Tunnel**: `cloudflared` runs on the instance as a systemd
  service, creating an outbound-only tunnel to Cloudflare.
  The instance has no public IP and no inbound ports open.
- **Auth**: LiteLLM's built-in virtual key system. Each user
  gets a key via `/key/generate`. Every request validated by
  LiteLLM before any Bedrock call. No custom auth middleware.
- **Master key**: Stored in SSM Parameter Store SecureString,
  injected at service startup. Never committed to source
  control.
- **IAM**: EC2 instance role with these permissions only:
  - `bedrock:InvokeModel`,
    `bedrock:InvokeModelWithResponseStream`
  - `ssm:GetParameter` (master key)
  - `ssmmessages:*` (Session Manager)
  - Role MUST NOT be exposed to end users.
- **Network**: Security group allows **no inbound traffic**.
  All connectivity is outbound-only:
  - `cloudflared` tunnel to Cloudflare (outbound HTTPS)
  - Bedrock API calls (outbound HTTPS)
  - SSM Session Manager (outbound HTTPS)
  No SSH, no port 22, no port 443, no port 80. The instance
  is invisible to the public internet.
- **Cloudflare Tunnel token**: Stored in SSM Parameter Store
  SecureString alongside the master key. Never committed to
  source control.

### III. LiteLLM-First

LiteLLM proxy is the entire application. Custom code MUST NOT
be written unless LiteLLM is provably unable to deliver the
feature via configuration, environment variables, or built-in
API.

**What LiteLLM handles (do not reimplement):**
- OpenAI-compatible surface (`/v1/chat/completions` with SSE
  streaming, `/v1/models`) — this is what Claude Code and
  other compatible CLI tools connect to.
- User authentication via virtual keys (requires PostgreSQL).
- Admin operations via `/key/generate`, `/key/delete`,
  `/key/info`, `/user/new`, `/user/delete` (curl + master
  key).
- Model routing to Bedrock via `config.yaml`.
- Per-key rate limiting and spend tracking (if needed).
- Key/user storage in PostgreSQL.

**What LiteLLM does NOT handle (the only custom work):**
- IaC to provision the instance, networking, IAM role.
- Instance bootstrap script (install LiteLLM, PostgreSQL,
  cloudflared; configure systemd; pull secrets from SSM).
- LiteLLM `config.yaml` defining Bedrock models and database
  connection.
- Systemd unit files for LiteLLM, PostgreSQL, and cloudflared.
- `rockport` bash CLI script: thin wrapper over LiteLLM's
  admin API + AWS CLI for day-to-day operations (key CRUD,
  status, logs, deploy). All data operations go through
  LiteLLM — the script only handles ergonomics (fetching
  master key from SSM, formatting output).

**Model switching:**
- Users MUST be able to switch models via `/model` slash
  commands in Claude Code. This works when
  `/v1/models` returns the available models.
- Model names in `config.yaml` MUST be mapped to clean,
  client-friendly aliases (e.g., `claude-sonnet-4-20250514`
  not `bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0`).
- Adding or removing a Bedrock model MUST require only a
  `config.yaml` change and service restart — no code changes.

**Rules:**
- If LiteLLM can do it, use LiteLLM. Do not write code.
- LiteLLM's admin UI MUST NOT be enabled.
- LiteLLM's built-in per-key `models` parameter MAY be used
  to scope which models a key can access (e.g., restricting
  Claude Code keys to Anthropic models only). This is native
  LiteLLM configuration, not custom auth code.
- Docker on EC2 MAY be used to run LiteLLM for reproducible
  deploys. Bare-metal pip install is also acceptable.

### IV. Scope Containment

Rockport is a LiteLLM proxy on EC2 with Bedrock. Nothing more.

**Out of scope (MUST NOT be built):**
- Web dashboard or GUI of any kind.
- Usage-based billing or payment processing.
- Prompt logging, caching, or transformation.
- Fine-tuning, RAG, or ML pipelines.
- Multi-tenant hierarchies (orgs, teams, roles).
- Custom model hosting.
- Webhooks, plugins, or extension systems.
- Third-party LLM providers (Bedrock only).
- Custom auth or key management code (the `rockport` bash CLI
  is permitted — it wraps LiteLLM's API, not replaces it).
- Any frontend (HTML, CSS, JavaScript).

**Before starting any work, answer:**
1. Does this serve the core use case? (Claude Code →
   Rockport → Bedrock models.)
2. Can LiteLLM already do this? If yes, configure — don't code.
3. Will this add more than £5/month to the AWS bill? If yes,
   find a cheaper way or reject.

### V. AWS London + Cloudflare

AWS `eu-west-2` (London) for compute and Bedrock. Cloudflare
(existing account, free plan) for DNS, TLS, and tunnel ingress.

- **Compute**: EC2 `t3.small` on-demand (2 vCPU, 2GB RAM).
  No public IP. ARM/Graviton incompatible with Prisma.
- **LLM backend**: Amazon Bedrock only. Required models MUST
  be explicitly enabled via Bedrock model access grants in
  the AWS account before deployment.
- **DNS/TLS**: Subdomain of `matthewdeaves.com` on Cloudflare.
  Cloudflare Tunnel for ingress. No Route 53.
- **Database**: PostgreSQL on the instance (local, no network
  exposure). LiteLLM virtual keys require PostgreSQL — SQLite
  is not supported for this feature.
- **Storage**: EBS volume (gp3). Automated EBS snapshots
  (daily, 7-day retention) MUST be configured to protect
  PostgreSQL data and LiteLLM config.
- **Secrets**: SSM Parameter Store SecureString for LiteLLM
  master key and Cloudflare Tunnel token.
- **IaC**: Terraform with AWS + Cloudflare providers.
- **CI/CD**: GitHub Actions — IaC validation, config lint,
  deploy.

**Availability:**
- The service MUST provide uninterrupted access during Claude
  Code and other compatible CLI tools sessions. The only acceptable causes of
  downtime are an AWS regional outage or a Cloudflare outage.
- LiteLLM, PostgreSQL, and cloudflared MUST each run under
  systemd with `Restart=always` so they auto-recover from
  crashes within seconds.
- EC2 auto-recovery MUST be enabled so the instance
  automatically restarts on underlying hardware failure.
- No Spot instances. On-demand only — interruptions are not
  acceptable.
- Upgrades (LiteLLM version, config changes, IaC changes)
  MUST be designed for minimal downtime. A brief restart
  (seconds) during a deploy is acceptable; extended outages
  are not.

## Governance

- This constitution is the highest-authority document for
  Rockport. All specs, plans, and tasks MUST comply.
- Scope Containment (IV) MUST be reviewed before accepting
  any new feature.
- This file MUST be re-read at the start of every planning
  session.
- The entire project (IaC, config, bootstrap scripts, docs)
  MUST be in git. Nothing required to deploy or run the
  service may exist outside the repository, except secrets
  stored in SSM and the Cloudflare Tunnel configuration.

**Version**: 0.1.0 | **Ratified**: 2026-03-13
