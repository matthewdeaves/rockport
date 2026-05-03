# AWS Access and IAM

How Rockport's IAM model works and which role to use for what. Hardened in
spec 017 to MFA-gated short-lived STS sessions across three operator roles.

## Operator roles (017)

The CLI maps every subcommand to one of three operator roles via
`SUBCOMMAND_ROLE` in `scripts/rockport.sh`. Each role is assumed via
MFA-gated `sts:AssumeRole`; sessions are 1 hour. Run
`./scripts/rockport.sh auth` once at session start; subsequent subcommands
reuse the cached session and only prompt for MFA again when escalating to
a different role or when a session expires.

### `rockport-readonly-role`
- **Used for:** diagnostics, model list, spend, monitor, key CRUD (HTTP
  to LiteLLM), `setup-claude`, `pentest`
- **Permissions:** EC2/SSM/CloudWatch/Logs/S3/CloudTrail read; SSM
  `GetParameter` on `/rockport/*`; CE `GetCostAndUsage`. **No
  `ssm:SendCommand`** (FR-008 / Finding A from Appserver 003 — readonly
  must not be silently root-on-the-box). **No IAM, no mutate.**
- **Subcommands:** `status` (without `--instance`), `models`, `spend`,
  `monitor`, `key list/info/create/revoke`, `setup-claude`

### `rockport-runtime-ops-role`
- **Used for:** in-VM operations that need shell on the instance
- **Permissions:** everything in readonly + `ssm:SendCommand` /
  `StartSession` on the rockport-tagged instance with documents
  `AWS-RunShellScript` and `AWS-StartInteractiveCommand`;
  `ec2:StartInstances`/`StopInstances` on the tagged instance;
  `s3:PutObject`/`DeleteObject` on `rockport-artifacts-*` and
  `rockport-video-*`
- **Subcommands:** `config push`, `upgrade`, `start`, `stop`, `logs`,
  `status --instance`

### `rockport-deploy-role`
- **Used for:** terraform apply / destroy
- **Permissions:** the three legacy deployer policies (compute,
  iam-ssm, monitoring-storage). The role boundary explicitly **denies**
  `iam:CreatePolicy*`, `iam:DeletePolicy*`, `iam:CreatePolicyVersion`,
  `iam:CreateUser`, `iam:AttachUserPolicy`, `iam:CreateAccessKey`
  (Finding B from Appserver 003 — a compromised deploy session can't
  rewrite its own boundary or mint access keys). IAM-policy and IAM-user
  mutation lives only on `RockportAdmin`.
- **Subcommands:** `deploy`, `destroy`

### Admin (default credential chain, no `AWS_PROFILE` set)
- **Used for:** `rockport.sh init` only — the bootstrap path that creates
  policies and users before operator roles exist
- **User:** `rockport-admin` (shared with Appserver in this AWS account)
- **Policy:** `RockportAdmin` (auto-created by init)

## When the CLI prompts for MFA

You only get a TOTP prompt when:
- The role for this subcommand has no cached `rockport-<role>` profile, OR
- The cached session is within 5 minutes of expiry / already expired

Cached sessions are reused silently. `rockport.sh auth status` shows
which roles have valid sessions and how much time is left.

The legacy long-lived `rockport` profile still works as a backwards-compat
fallback through phase 4 of the 017 rollout (with a one-time deprecation
warning per shell). Phase 5 removes it.

## Escape hatch: `ROCKPORT_AUTH_DISABLED=1`

For the very first `rockport.sh init` on a fresh AWS account (when
operator roles don't exist yet), set `ROCKPORT_AUTH_DISABLED=1` to skip
role assumption entirely. The CLI then uses the default credential chain.
This is documented in `specs/017-iam-mfa-scoping/HANDOFF.md`.

## Cross-project safety

`rockport-admin` is shared with Appserver (matthewdeaves/appserver) in
the same AWS account. Rockport's `iam-ssm.json` deny is resource-scoped
to `arn:aws:iam::*:role/rockport*` so it does NOT block Appserver IAM
operations. If you reintroduce a similar deny in Rockport's policies,
keep it Resource-scoped — never Resource: `*`.

## Capabilities detail (deploy role)

The deploy role inherits the three legacy deployer policies, with the
boundary explicitly denying IAM-policy / IAM-user / access-key mutation.

### Compute (deployer-policies/compute.json)
- EC2: Full describe, create/modify/terminate with `Project=rockport` tag
- Lambda: Full management for `rockport-*` functions
- DLM: Lifecycle policy management (EBS snapshots)

### IAM + SSM (deployer-policies/iam-ssm.json)
- IAM: Manage `rockport*` roles, instance profiles. Read-only on the
  policies that bound the role itself (no policy mutation —
  `iam:CreatePolicyVersion` etc. were removed in 017 / Finding B).
- SSM: SendCommand + StartSession to rockport-tagged instances
- SSM documents: Only `AWS-RunShellScript` and `AWS-StartInteractiveCommand`
- **Security:** Explicit Deny on `AttachRolePolicy`/`DetachRolePolicy`
  scoped to Rockport roles (017 / D8 — does not affect Appserver-* roles
  in the shared account). Belt-and-braces `DenyAttachToInstanceRole`.

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

Terraform uses the deploy operator role (017). Don't invoke `terraform`
directly — go through `rockport.sh deploy` / `destroy`, which assumes
`rockport-deploy-role` first:

```bash
cd $PROJECT_ROOT
./scripts/rockport.sh deploy   # prompts for MFA on first call this hour
./scripts/rockport.sh destroy
```

The Cloudflare API token is in `terraform/.env` (gitignored):
```bash
source $PROJECT_ROOT/terraform/.env
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
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
```

Default is `eu-west-2` (London). Bedrock cross-region inference profiles route to other EU regions automatically.
