# Quickstart: Security Hardening

## Prerequisites

- Existing Rockport deployment on `007-security-hardening` branch
- Cloudflare API token with Zone WAF Edit + Access Edit permissions
- AWS credentials with deployer role permissions

## Deployment Order

These changes should be applied in this order to minimize disruption:

### 1. IAM Policy Restriction (zero downtime)
Edit `terraform/deployer-policies/iam-ssm.json` to add the Deny statement. Apply with `terraform apply`. No service restart needed.

### 2. PostgreSQL SCRAM-SHA-256 (new instances only)
Edit `scripts/bootstrap.sh` and `config/postgresql-tuning.conf`. This only takes effect on fresh instance bootstrap — existing instances are unaffected.

### 3. Systemd Hardening (service restart required)
Edit all three `.service` files in `config/`. Push with `./scripts/rockport.sh config push` which copies files and restarts services. Brief downtime (~5 seconds per service).

### 4. Lambda Monitoring Improvements (zero downtime)
Edit `terraform/idle.tf` to add CPU metric check and error alarm. Apply with `terraform apply`. Lambda updates atomically.

### 5. Video Job Concurrency Fix (service restart required)
Edit `sidecar/db.py` and `sidecar/video_api.py`. Push with `./scripts/rockport.sh config push`. Brief downtime for video sidecar only.

### 6. Cloudflare Access (requires client updates)
Apply Terraform changes to create Access application + service token. **All clients must be updated with service token headers before or immediately after this step**, or they will be blocked.

## Post-Deployment Verification

```bash
# Run smoke tests (must include service token headers after step 6)
./tests/smoke-test.sh https://llm.matthewdeaves.com <api-key>

# Verify IAM restriction
aws iam simulate-principal-policy \
  --policy-source-arn <deployer-role-arn> \
  --action-names iam:AttachRolePolicy \
  --resource-arns arn:aws:iam::<account>:role/rockport-instance-role \
  --context-entries Key=iam:PolicyARN,Values=arn:aws:iam::aws:policy/AdministratorAccess,Type=string

# Check systemd security scores
ssh (via SSM) → systemd-analyze security litellm.service
ssh (via SSM) → systemd-analyze security cloudflared.service
ssh (via SSM) → systemd-analyze security rockport-video.service

# Verify Lambda alarm exists
aws cloudwatch describe-alarms --alarm-names rockport-idle-shutdown-errors
```

## Client Configuration Update (after step 6)

### Claude Code
Add to Claude Code configuration:
```json
{
  "defaultHeaders": {
    "CF-Access-Client-Id": "<client-id-from-terraform-output>",
    "CF-Access-Client-Secret": "<client-secret-from-terraform-output>"
  }
}
```

### Admin CLI
The `rockport.sh` script will automatically read the service token from Terraform outputs or environment variables and include the headers in all curl calls.

## Rollback

Each change is independently reversible:
- IAM: Remove the Deny statement and re-apply
- PostgreSQL: Revert bootstrap.sh (only affects new instances)
- Systemd: Remove the new directives and push config
- Lambda: Revert idle.tf and re-apply
- Video sidecar: Revert db.py/video_api.py and push config
- Cloudflare Access: Delete the Access application in Terraform (removes auth requirement immediately)
