# AWS Access and IAM

How Rockport's two-tier IAM model works and which profile to use for what.

## Profiles

### Deployer Profile (`AWS_PROFILE=rockport`)
- **Used for:** All routine operations (diagnostics, deploy, key management, config push, spend)
- **User:** `rockport-deployer` IAM user
- **Created by:** `rockport.sh init`
- **Policies:** 3 deployer policies (compute, iam-ssm, monitoring-storage)

### Admin Profile (default / no AWS_PROFILE)
- **Used for:** Bootstrap only (`rockport.sh init`)
- **User:** Your personal IAM user (must have admin-level access)
- **Policy:** `rockport-admin-policy.json` (auto-created by init)

## When to Use Each

### Use Deployer (default for rockport-ops)

Almost everything:
- `aws ec2 describe-instances` (instance status)
- `aws ssm send-command` / `describe-instance-information` (remote commands)
- `aws ssm get-parameter` (read secrets like master key)
- `aws s3 cp` (upload/download artifacts)
- `aws cloudwatch describe-alarms` (alarm status)
- `aws logs filter-log-events` (Lambda logs)
- `aws ce get-cost-and-usage` (spend data)
- `terraform plan` / `terraform apply` / `terraform destroy`
- All `rockport.sh` commands except `init`

### Use Admin (escalation only)

Only when the issue involves:
- Creating or modifying IAM policies (e.g., adding a new Bedrock model family to the instance role)
- Creating or modifying IAM users
- Managing the state bucket DenyNonSSL policy
- First-time setup (`rockport.sh init`)

**To escalate:** Unset the deployer profile:
```bash
unset AWS_PROFILE
# Now commands use the default credential chain (your admin user)
```

**Rockport-ops should almost never need admin.** If a fix requires IAM policy changes, those changes should go through terraform (which runs as the deployer), not manual IAM API calls.

## Deployer Capabilities Detail

### Compute (deployer-policies/compute.json)
- EC2: Full describe, create/modify/terminate with `Project=rockport` tag
- Lambda: Full management for `rockport-*` functions
- DLM: Lifecycle policy management (EBS snapshots)

### IAM + SSM (deployer-policies/iam-ssm.json)
- IAM: Manage `rockport*` roles, instance profiles, policies
- SSM: SendCommand + StartSession to rockport-tagged instances
- SSM documents: Only `AWS-RunShellScript` and `AWS-StartInteractiveCommand`
- **Security:** Explicit Deny on AttachRolePolicy/DetachRolePolicy for non-Rockport policies

### Monitoring + Storage (deployer-policies/monitoring-storage.json)
- CloudWatch: Logs, alarms, EventBridge for `rockport-*` resources
- S3: Full access to `rockport-tfstate-*`, `rockport-artifacts-*`, `rockport-video-*` buckets
- CloudTrail: Manage `rockport-*` trails
- Cost Explorer: Read-only

## SSM Command Patterns

### Send a command and get output
```bash
# Send
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"$YOUR_COMMAND\"]}" \
  --query 'Command.CommandId' --output text --region "$REGION")

# Wait briefly for execution
sleep 3

# Get result
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

### Important SSM notes
- Commands run as `root` by default on the instance
- Timeout default is 3600 seconds; most diagnostic commands finish in < 5 seconds
- If SSM times out, the instance may be starting up (wait 2-3 min) or unreachable
- The deployer can only use `AWS-RunShellScript` and `AWS-StartInteractiveCommand` documents

## Terraform Credentials

Terraform uses the deployer profile. The backend config is in `terraform/`:
```bash
cd /home/matt/rockport/terraform
AWS_PROFILE=rockport terraform plan
AWS_PROFILE=rockport terraform apply
```

The Cloudflare API token is in `terraform/.env` (gitignored):
```bash
source /home/matt/rockport/terraform/.env
# Sets CLOUDFLARE_API_TOKEN
```

## Secret Locations

| Secret | Location | Access |
|--------|----------|--------|
| LiteLLM master key | SSM `/rockport/master-key` | Deployer (read), Admin (write) |
| Tunnel token | SSM `/rockport/tunnel-token` | Terraform manages |
| DB password | SSM `/rockport/db-password` | Bootstrap generates |
| CF API token | `terraform/.env` | Local file, gitignored |
| CF Access client ID | Terraform output (sensitive) | `terraform output cf_access_client_id` |
| CF Access client secret | Terraform output (sensitive) | `terraform output cf_access_client_secret` |

## Region

Region is read from `terraform/terraform.tfvars`, not hardcoded:
```bash
REGION=$(grep '^region' /home/matt/rockport/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
```

Default is `eu-west-2` (London). Bedrock cross-region inference profiles route to other EU regions automatically.
