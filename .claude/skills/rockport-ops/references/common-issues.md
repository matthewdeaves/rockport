# Common Issues

Known symptom-to-cause mappings for Rockport infrastructure. Organized by symptom category.

## Connection Failures

### HTTP 403 from Cloudflare Access
**Symptoms:** All requests return 403, "Access denied" page
**Cause:** Missing or invalid CF-Access-Client-Id / CF-Access-Client-Secret headers
**Check:** Are headers being sent? Has the service token been rotated in Terraform without updating clients?
**Fix:** Verify token values match `terraform output cf_access_client_id` and `cf_access_client_secret`

### HTTP 403 from Cloudflare WAF
**Symptoms:** Specific paths return 403, others work fine
**Cause:** Path not in WAF allowlist (`terraform/waf.tf`)
**Check:** Compare the failing path against the WAF rule expressions
**Fix:** Add path to WAF allowlist in `terraform/waf.tf`, deploy

### HTTP 403 with Python user-agent
**Symptoms:** Requests from Python scripts return 403, curl works fine
**Cause:** Cloudflare blocks the default `Python-urllib` user-agent
**Fix:** Set a custom User-Agent header. OpenAI SDK does this automatically

### Connection timeout / refused
**Symptoms:** Requests hang or get connection refused
**Causes (in order of likelihood):**
1. Instance stopped by idle shutdown (most common) - check instance state
2. cloudflared tunnel not running - check systemd status
3. LiteLLM not running - check systemd status
4. Instance still bootstrapping after start (~3 min)

### HTTP 502 Bad Gateway
**Symptoms:** Intermittent 502s through the tunnel
**Cause:** LiteLLM or sidecar process crashed/restarting, tunnel routing to dead port
**Check:** Service status and recent restart count in systemd

## LiteLLM Issues

### LiteLLM service won't start
**Symptoms:** `systemctl status litellm` shows failed
**Common causes:**
1. PostgreSQL not running (LiteLLM needs it for virtual keys)
2. Prisma client corruption (cache mismatch)
3. Config syntax error in `litellm-config.yaml`
4. Port 4000 already in use
**Check:** `journalctl -u litellm --no-pager -n 50` for the startup error

### LiteLLM OOM killed
**Symptoms:** Service suddenly stops, `dmesg | grep -i oom` shows LiteLLM killed
**Cause:** t3.small has 2GB RAM. LiteLLM is limited to 1280MB, sidecar to 256MB, PostgreSQL uses ~100MB. Memory pressure from large requests or connection buildup can trigger OOM
**Check:** `journalctl -k | grep -i oom` and `free -h`
**Fix:** Check if MemoryMax settings in systemd units are appropriate. Consider if a request pattern is causing memory bloat

### Model not found
**Symptoms:** `model_not_found` error for a model that should exist
**Causes:**
1. Model alias missing from `config/litellm-config.yaml`
2. Claude Code sending an old model ID not in the alias list
3. Bedrock model not enabled in the AWS account
**Check:** Compare the requested model ID against aliases in litellm-config.yaml

### Authentication failures (401)
**Symptoms:** Valid API key returns 401
**Causes:**
1. Key expired or revoked
2. Key budget exceeded
3. Master key changed (SSM parameter updated without restarting LiteLLM)
**Check:** `./scripts/rockport.sh key info <key>` for key status and spend

## Sidecar Issues (Video + Image)

### Sidecar health returns unhealthy
**Symptoms:** `localhost:4001/health` returns error or connection refused
**Cause:** Python process crashed, usually due to:
1. PostgreSQL connection failure (sidecar needs DB for job tracking)
2. Import error (missing dependency)
3. Port conflict
**Check:** `journalctl -u rockport-video --no-pager -n 50`

### Video job stuck in pending
**Symptoms:** Job created but never moves to in_progress
**Causes:**
1. Bedrock async invoke failed silently (IAM issue)
2. S3 bucket permissions (Bedrock needs PutObject on the video bucket)
3. Region mismatch (Nova Reel needs us-east-1 bucket, Ray2 needs us-west-2)
**Check:** Sidecar logs for Bedrock error, check IAM role policies

### Video job stuck in in_progress
**Symptoms:** Job started but never completes
**Cause:** Bedrock async invoke still running (can take minutes for long videos), or the polling loop lost track of the job
**Check:** Sidecar logs for the job's Bedrock ARN, check Bedrock async invoke status directly

### Concurrent job limit reached (429)
**Symptoms:** "concurrent job limit reached" error
**Cause:** Per-key limit (default 3) exceeded. Jobs may be stuck or legitimately running
**Check:** Query the video jobs table for active jobs for that key

### Image endpoint 404
**Symptoms:** `/v1/images/variations` or similar returns 404
**Cause:** Request going to LiteLLM (:4000) instead of sidecar (:4001). Check tunnel routing in `terraform/tunnel.tf`
**Note:** `/v1/images/generations` and `/v1/images/edits` intentionally route to LiteLLM. Only `/v1/images/*` (other paths) routes to sidecar

### --claude-only key blocked (403)
**Symptoms:** Image or video request returns 403 "restricted to Anthropic models"
**Cause:** Key was created with `--claude-only` flag, which blocks non-Anthropic models (images, video)
**Fix:** Create a new key without `--claude-only`, or use an existing unrestricted key

## Bedrock Issues

### Throttling (429 from Bedrock)
**Symptoms:** Intermittent 429 errors, "Too many requests"
**Cause:** Bedrock per-model rate limits exceeded
**Check:** CloudWatch metrics for Bedrock throttling. LiteLLM logs will show the 429
**Note:** Cross-region inference profiles help distribute load but each region has its own limits

### Model access denied
**Symptoms:** `AccessDeniedException` from Bedrock
**Causes:**
1. Model not enabled in Bedrock console for that region
2. IAM policy doesn't cover the model family pattern
3. Marketplace subscription needed (Stability AI, Luma Ray2)
**Check:** Compare the model ARN in the error against IAM policy patterns in `terraform/main.tf`

### Stability AI / Luma models fail on first use
**Symptoms:** 403 or subscription error for stability-* or luma-* models
**Cause:** Marketplace subscription not activated. These models require a one-time subscription
**Fix:** Invoke the model once in the Bedrock playground in the AWS console to activate. This is a manual step that cannot be automated

## Infrastructure Issues

### Instance won't start
**Symptoms:** `aws ec2 start-instances` returns error or instance stays in "pending"
**Causes:**
1. Insufficient capacity in the AZ (rare for t3.small)
2. EBS volume issue
3. Account-level EC2 limit reached
**Check:** EC2 console events tab, or `aws ec2 describe-instance-status`

### SSM not reachable
**Symptoms:** SSM commands time out, instance shows "Connection Lost"
**Causes:**
1. Instance just started (SSM agent takes 1-2 minutes after boot)
2. Instance has no outbound internet (public IP removed, or route table broken)
3. SSM agent crashed
**Check:** Wait 2-3 minutes after start. If still unreachable, check VPC route table and public IP assignment

### Config push fails
**Symptoms:** `rockport.sh config push` errors
**Causes:**
1. Instance not running
2. SSM not reachable
3. S3 upload failed (IAM or bucket issue)
4. Service restart failed after config extraction
**Check:** The SSM command output includes the bash script output. Look for which step failed

### Terraform state lock
**Symptoms:** `terraform apply` says state is locked
**Cause:** Previous terraform operation crashed or is still running
**Fix:** Check if another operation is genuinely running. If not, `terraform force-unlock <LOCK_ID>` (use with caution)

## PostgreSQL Issues

### PostgreSQL not running
**Symptoms:** LiteLLM and sidecar both fail, both need PostgreSQL
**Check:** `systemctl status postgresql` via SSM
**Common cause:** Disk full (check with `df -h`), or OOM killed
**Fix:** Restart PostgreSQL, then restart LiteLLM and sidecar (order matters)

### Connection pool exhausted
**Symptoms:** "too many connections" errors in LiteLLM or sidecar logs
**Cause:** max_connections (30 for t3.small tuning) exceeded
**Check:** `SELECT count(*) FROM pg_stat_activity;` via SSM
**Fix:** Restart services to release connections. If recurring, check for connection leaks

## Cost-Related Issues

### Unexpected high spend
**Symptoms:** Budget alarm fires, spend today shows high values
**Check:** `./scripts/rockport.sh spend today` to see breakdown by key and model
**Common causes:**
1. Runaway automation (Claude Code in a loop)
2. Video generation (expensive: $0.08/s Nova Reel, $0.75-1.50/s Ray2)
3. Idle shutdown not working (instance running 24/7)
**Fix:** Revoke the offending key if needed, check idle shutdown Lambda logs

### Idle shutdown not firing
**Symptoms:** Instance runs continuously, Lambda not triggering
**Check:** CloudWatch alarm `rockport-idle-shutdown-errors`, Lambda logs
**Cause:** Lambda function error, CloudWatch Events rule disabled, or instance genuinely active
