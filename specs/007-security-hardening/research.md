# Research: Security Hardening

## R1: IAM Condition to Restrict Policy Attachment

**Decision**: Add an explicit Deny statement with `StringNotLike` condition on `iam:PolicyARN` to block attachment of any policy not matching `arn:aws:iam::*:policy/Rockport*` or `arn:aws:iam::*:policy/rockport*`.

**Rationale**: IAM conditions on Allow statements with `iam:PolicyARN` are supported but an explicit Deny is stronger — it cannot be overridden by any Allow in other policies. The condition key `iam:PolicyARN` is the correct global condition key for `AttachRolePolicy` and `DetachRolePolicy` actions.

**Alternatives considered**:
- *Remove AttachRolePolicy entirely*: Would break Terraform applies that attach managed policies to rockport roles. Rejected.
- *Condition on Allow statement*: Works but can be overridden by a broader Allow elsewhere. Less secure than explicit Deny.
- *Permissions boundary*: More complex to manage and would require changes to all role creation. Overkill for this use case.

**Implementation detail**: Add a new Statement to `iam-ssm.json`:
```json
{
  "Sid": "DenyNonRockportPolicyAttachment",
  "Effect": "Deny",
  "Action": [
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy"
  ],
  "Resource": "*",
  "Condition": {
    "StringNotLike": {
      "iam:PolicyARN": [
        "arn:aws:iam::*:policy/Rockport*",
        "arn:aws:iam::*:policy/rockport*"
      ]
    }
  }
}
```

## R2: Cloudflare Access Service Token Architecture

**Decision**: Create a Cloudflare Access application for the tunnel domain with a Service Auth policy requiring a service token. The service token's Client ID and Client Secret are passed as `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers.

**Rationale**: Cloudflare Access service tokens are designed for machine-to-machine authentication. They work with the Cloudflare provider's `cloudflare_zero_trust_access_application`, `cloudflare_zero_trust_access_policy`, and `cloudflare_zero_trust_access_service_token` resources. The service token approach is ideal because all Rockport clients are programmatic (Claude Code, admin CLI, curl).

**Alternatives considered**:
- *Cloudflare Access with identity provider (e.g., GitHub OAuth)*: Requires browser-based login. Not compatible with CLI tools sending API requests. Rejected.
- *mTLS client certificates*: More complex to manage and distribute. Overkill for single-operator setup. Rejected.
- *IP allowlisting in WAF*: Fragile — operator IP changes. Doesn't work from mobile or different networks. Rejected.

**Implementation detail**:
- New file `terraform/access.tf` with 3 resources: `cloudflare_zero_trust_access_application`, `cloudflare_zero_trust_access_policy`, `cloudflare_zero_trust_access_service_token`
- Service token Client ID and Secret output as Terraform outputs (sensitive)
- Admin CLI (`rockport.sh`) and smoke tests need `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers added to all curl calls
- Claude Code configuration needs `defaultHeaders` with the service token headers

**Client impact**: All existing clients must be updated to include the two headers. The `setup-claude` command should output the headers in its Claude Code config snippet.

## R3: Systemd @system-service Syscall Set Compatibility

**Decision**: Use `SystemCallFilter=@system-service` for all three services. This is the standard systemd-recommended set for typical system services and includes all syscalls needed by Python 3.11, Go binaries, and PostgreSQL client libraries.

**Rationale**: The `@system-service` set is specifically designed as a reasonable default for system services. It includes networking, file I/O, memory management, threading, and signal handling — everything LiteLLM (Python/uvicorn), cloudflared (Go), and the video sidecar (Python/FastAPI) need. It excludes dangerous syscalls like `reboot`, `kexec_load`, `mount`, `pivot_root`, etc.

**Alternatives considered**:
- *Custom minimal syscall list*: Would require extensive testing and could break on Python/Go runtime updates. Too fragile. Rejected.
- *@system-service + @network-io*: `@network-io` is already included in `@system-service`. Redundant.
- *No SystemCallFilter, only other directives*: Misses the highest-impact hardening directive. Rejected.

**Risk mitigation**: If a service fails to start after adding `SystemCallFilter=@system-service`, the fix is to add `SystemCallFilter=~` (allow-all) temporarily, then use `strace` to identify the blocked syscall and add it explicitly.

## R4: SCRAM-SHA-256 Migration

**Decision**: Change `md5` to `scram-sha-256` in both `pg_hba.conf` sed commands in `bootstrap.sh`. Also set `password_encryption = scram-sha-256` in `postgresql.conf` to ensure new passwords are stored with SCRAM.

**Rationale**: PostgreSQL 10+ supports SCRAM-SHA-256, PostgreSQL 14+ defaults to it for new installations. Since bootstrap.sh creates the user and sets the password in the same script, the password will be stored with SCRAM hashing from the start. No migration needed — this only affects fresh deployments.

**Alternatives considered**:
- *Leave as md5*: Technically safe for localhost-only traffic but fails audit checks. Rejected.
- *Certificate-based auth*: Overkill for localhost connections where both client and server run on the same instance. Rejected.

**Implementation detail**:
1. In `bootstrap.sh`, change both `md5` strings to `scram-sha-256` (lines 49-50)
2. Add `password_encryption = scram-sha-256` to the postgresql-tuning.conf heredoc (line 38-44)
3. Existing deployed instances are unaffected — this only applies to new bootstraps

## R5: Lambda Error Alarm and CPU Metric

**Decision**: Add a CloudWatch alarm on the Lambda's `Errors` metric and extend the Lambda code to also check `CPUUtilization`.

**Rationale**: The `Errors` metric is automatically published by Lambda — no code changes needed for the alarm. For CPU, CloudWatch publishes `CPUUtilization` for EC2 instances by default (no CloudWatch agent needed), so the Lambda can query it alongside `NetworkIn`.

**Alternatives considered**:
- *SNS notification on instance stop*: Only alerts on stops, not on Lambda failures. Doesn't address the blind spot. Rejected as insufficient (but could be added separately).
- *CloudWatch agent for custom metrics*: Adds cost and complexity. Default EC2 metrics are sufficient. Rejected.
- *Dead letter queue on Lambda*: More complex than a simple error alarm. Overkill. Rejected.

**Implementation detail**:
1. New `aws_cloudwatch_metric_alarm` resource in `idle.tf` on `AWS/Lambda` namespace, `Errors` metric, `Sum` statistic, threshold 1, evaluation periods 2 (two consecutive 5-minute failures = alarm)
2. Lambda code: add second `get_metric_statistics` call for `CPUUtilization`, threshold at 10% (idle instance typically < 5%)
3. Instance is only stopped if BOTH NetworkIn < 500KB AND CPUUtilization < 10%
4. Alarm action: SNS topic (new resource) — requires an email subscription configured manually post-deploy, or leave as alarm-only (visible in CloudWatch console)

**Cost note**: First 10 CloudWatch alarms are free. SNS topic with email subscription is free tier.

## R6: Advisory Lock for Video Job Concurrency

**Decision**: Replace the separate `count_in_progress_jobs` + `insert_job` calls with a single database function that uses `pg_advisory_xact_lock` to atomically check the count and insert within one transaction.

**Rationale**: PostgreSQL advisory locks are lightweight, per-transaction, and automatically released on commit/rollback. Using a hash of the API key as the lock ID ensures different keys don't block each other. The lock is held only for the duration of the count+insert, so contention is minimal.

**Alternatives considered**:
- *Serializable transaction isolation*: Heavier than advisory locks. Can cause serialization failures that need retry logic. Rejected.
- *Unique partial index + INSERT ... ON CONFLICT*: Can't enforce a count-based limit with a unique index. Rejected.
- *Application-level mutex (threading.Lock)*: Only works within a single process. Doesn't protect against multiple uvicorn workers (though currently single-worker). Fragile. Rejected.

**Implementation detail**:
1. New function in `db.py`: `insert_job_if_under_limit(api_key_hash, max_concurrent, ...)` that:
   - Opens a transaction
   - Acquires `pg_advisory_xact_lock(hashtext(api_key_hash))`
   - Counts in-progress jobs
   - If under limit, inserts and returns the job
   - If at/over limit, returns None (caller raises 429)
   - Lock auto-releases on transaction commit
2. `video_api.py`: Replace the two-step check with a single call to the new function
3. Keep `count_in_progress_jobs` for read-only use (e.g., status endpoints)
