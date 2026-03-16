# Research: Video Generation Sidecar

## R1: Can LiteLLM handle Bedrock video generation natively?

**Decision**: No — custom sidecar required.

**Rationale**: LiteLLM (as of v1.82.x) has no proxy endpoint for Bedrock async video generation. Bedrock video uses `StartAsyncInvoke`/`GetAsyncInvoke` (async with S3 output), which is fundamentally different from the synchronous `InvokeModel` that LiteLLM wraps. LiteLLM added experimental video support for Google Veo but not for Bedrock's async model. This satisfies Constitution III (LiteLLM-First): LiteLLM is provably unable to deliver this feature.

**Alternatives considered**:
- Fork LiteLLM: Rejected — massive codebase (~200k+ lines), frequent releases, merge burden
- Wait for LiteLLM support: No timeline, async pattern is architecturally different from their sync model

## R2: Sidecar framework choice

**Decision**: FastAPI with uvicorn

**Rationale**: FastAPI is already available on the instance (LiteLLM depends on it internally via starlette). Uvicorn is also already installed as a LiteLLM dependency. No additional pip packages needed for the web framework. Python 3.11 is already installed. boto3 is available via the AWS CLI.

**Alternatives considered**:
- Flask: Would need additional install; no async support without gevent
- aiohttp: Would need additional install; less ergonomic than FastAPI
- Plain starlette: FastAPI adds negligible overhead and provides validation via pydantic (also already installed)

## R3: Job metadata storage

**Decision**: Use LiteLLM's existing PostgreSQL database with a new `rockport_video_jobs` table.

**Rationale**: PostgreSQL is already running on the instance. Using the same database keeps operations simple (single backup target, single connection string). A separate table avoids touching LiteLLM's schema. The sidecar reads the DB password from the same env file or SSM parameter.

**Alternatives considered**:
- SQLite: Would work for low volume but adds a second database to manage/backup
- In-memory with Bedrock as source of truth: Loses job-to-key mapping on restart; `ListAsyncInvokes` doesn't filter by API key
- Separate PostgreSQL database: Unnecessary complexity for a few hundred rows

## R4: Spend tracking integration

**Decision**: Write directly to `LiteLLM_SpendLogs` table AND update `LiteLLM_VerificationToken.spend`.

**Rationale**: LiteLLM's spend reports (`/global/spend`, `/key/list`) read from these tables. Writing to `LiteLLM_SpendLogs` makes video costs appear in `rockport.sh spend` and `rockport.sh monitor` with zero CLI changes. The `spend` column on `LiteLLM_VerificationToken` must also be incremented for budget enforcement to work correctly (LiteLLM checks this column for budget limits).

**Alternatives considered**:
- LiteLLM custom callback: Would require modifying LiteLLM config and writing a Python callback module — more coupling
- Separate spend tracking: Would require CLI changes and wouldn't appear in unified reports

## R5: Authentication approach

**Decision**: Validate keys by calling LiteLLM's `/key/info` endpoint on localhost.

**Rationale**: The sidecar calls `GET http://127.0.0.1:4000/key/info?key=<user-key>` with the master key. This returns key metadata including `spend`, `max_budget`, and `models` list. No custom auth code — just delegating to LiteLLM's existing validation. The master key is already available in `/etc/litellm/env`.

**Alternatives considered**:
- Direct database lookup: Would bypass LiteLLM's caching and hash logic
- Shared secret/JWT: Would be custom auth code (Constitution IV violation)

## R6: Cloudflare tunnel routing

**Decision**: Configure cloudflared to route `/v1/videos/*` to the sidecar port (4001) and everything else to LiteLLM (4000).

**Rationale**: Cloudflare Tunnel supports path-based routing via the tunnel config. The tunnel config is managed in the Cloudflare dashboard (not in Terraform currently). The sidecar runs on port 4001 on localhost. Cloudflared routes based on path prefix.

**Update**: Actually, Cloudflare Tunnel ingress rules are set in the dashboard or via `cloudflared tunnel route`. The current setup uses a tunnel token which means the config is in the Cloudflare dashboard. We'll need to either:
1. Add a second service in the Cloudflare Tunnel dashboard config, OR
2. Use a reverse proxy (nginx) on the instance to route by path

**Revised decision**: Use nginx as a lightweight local reverse proxy. It routes `/v1/videos/*` to port 4001 (sidecar) and everything else to port 4000 (LiteLLM). Cloudflared points to nginx on port 8080. This avoids needing to change the Cloudflare Tunnel dashboard config per-path.

Wait — actually, this adds nginx as a new dependency, which adds complexity. Simpler approach: the sidecar itself can proxy non-video requests to LiteLLM. But that's even worse.

**Final decision**: Have the sidecar listen on port 4001. Configure the Cloudflare Tunnel to send all traffic to a single origin (port 4000, LiteLLM). Add the video paths to WAF allowlist. Then configure LiteLLM as a pass-through — actually LiteLLM will just 404 on `/v1/videos/*`.

**Actual final decision**: The simplest approach is to run the sidecar on a separate path and route at the Cloudflare Tunnel level. Since the tunnel token config supports multiple ingress rules with path matching, we configure:
- `path: /v1/videos/*` → `http://localhost:4001`
- `*` (catch-all) → `http://localhost:4000`

This is configured via the Cloudflare dashboard (Zero Trust > Networks > Tunnels > Public Hostname). No nginx needed, no code changes to LiteLLM.

## R7: Memory constraints on t4g.small (2GB)

**Decision**: Reduce LiteLLM MemoryMax from 1536M to 1280M, allocate 256M to the sidecar.

**Rationale**: Current allocation: LiteLLM 1536M + cloudflared 256M = 1792M on a 2048M instance. With 512M swap already configured, there's headroom. The sidecar is lightweight (FastAPI + boto3, no ML models). Reducing LiteLLM to 1280M and giving the sidecar 256M keeps total at 1792M. LiteLLM typically uses 400-600M in practice.

**Alternatives considered**:
- Upgrade to t4g.medium (4GB): Violates Constitution I (cost)
- No memory limit on sidecar: Risky on a shared instance

## R8: S3 bucket cost estimate

**Decision**: S3 cost is negligible (<$0.10/month).

**Rationale**: At the expected usage (handful of accounts, ~8 hours/day), estimate ~10-20 videos/day max. A 120-second video at 720p/24fps is ~50-100MB. 20 videos × 100MB × 7 days retention = 14GB max. S3 Standard in us-east-1: $0.023/GB/month = ~$0.32/month. Well under the £5 threshold from Constitution IV.

## R9: Nova Reel API specifics

**Decision**: Use `amazon.nova-reel-v1:1` (latest) in us-east-1.

**Rationale**: Nova Reel v1.1 supports both single-shot and multi-shot modes. Only available in us-east-1. The EC2 instance makes cross-region boto3 calls to us-east-1 (same pattern as existing image generation models). The S3 output bucket must also be in us-east-1 (Bedrock writes directly to it).

**Key API details**:
- `StartAsyncInvoke`: Returns `invocationArn` immediately
- `GetAsyncInvoke`: Returns status + output S3 URI on completion
- Output format: MP4 at `{s3Uri}/output.mp4`
- Single-shot: `taskType: TEXT_VIDEO`, `textToVideoParams.text`, `videoGenerationConfig.durationSeconds`
- Multi-shot manual: `textToVideoParams.videos[]` array with per-shot `text` and optional `imageDataURI`
- Duration must be multiple of 6, range 6-120 seconds
- Resolution fixed at 1280x720, fps fixed at 24

## R10: IAM permissions needed

**Decision**: Add `bedrock:StartAsyncInvoke`, `bedrock:GetAsyncInvoke`, `bedrock:ListAsyncInvokes` for us-east-1, plus S3 permissions for the video bucket.

**Rationale**: Current IAM only allows `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`. The async invoke actions are separate. S3 permissions needed for Bedrock to write video output and for the sidecar to generate presigned URLs.

This is a Constitution II deviation — IAM scope expands beyond the listed actions. Justified because video generation requires these actions and doesn't expose the role to end users.
