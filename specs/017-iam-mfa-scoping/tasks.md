# Tasks: Rockport IAM MFA + Per-Skill Scoping

**Input**: Design documents from `/specs/017-iam-mfa-scoping/`
**Prerequisites**: spec.md, plan.md

**Tests**: Existing — `bash pentest/pentest.sh run rockport`. New — `tests/auth-flow-test.sh` for the CLI auth helpers added in phase 3.

**Format**: `[ID] [P?] [Phase] Description`
- **[P]**: Can run in parallel (different files, no dependencies)

---

## Phase 1 — Additive: roles + boundaries + tightening

### Setup
- [ ] **T001** Create branch `017-iam-mfa-scoping` from `main`. Confirm `pre-commit` hooks active (`gitleaks`, `shellcheck`).

### Policies (parallel: separate files)
- [ ] **T002** [P] Create `terraform/deployer-policies/readonly.json`. Read-only across:
  - EC2: `Describe*`
  - DLM: `Get*`, `ListTagsForResource`
  - SSM: `GetParameter` on `/rockport/*`, `GetCommandInvocation`, `DescribeInstanceInformation`, `ListCommandInvocations`, `ListCommands`, `DescribeParameters`
  - CloudWatch: `Get*`, `Describe*`, `List*`
  - CE: `GetCostAndUsage`
  - Logs: `Get*`, `FilterLogEvents`, `DescribeLogGroups`, `DescribeLogStreams`
  - S3 read: `rockport-artifacts-*`, `rockport-tfstate-*`, `rockport-video-*`, `rockport-cloudtrail-*`
  - CloudTrail: `DescribeTrails`, `GetTrailStatus`, `LookupEvents`
  - Lambda: `GetFunction*`, `ListFunctions`, `ListVersionsByFunction`, `ListTags`
  - Budgets: `DescribeBudget*`, `ViewBudget`
  - Bedrock: `ListFoundationModels`, `GetFoundationModel`, `ListInferenceProfiles`
  - STS: `GetCallerIdentity`
  - **Explicitly NO**: `ssm:SendCommand`, `ssm:StartSession`, any `iam:*`, any `Modify*`, any `Put*`, any `Delete*`, any `Create*`, any S3 Write/Delete.
- [ ] **T003** [P] Create `terraform/deployer-policies/runtime-ops.json`. Includes everything in `readonly.json` PLUS:
  - `ssm:SendCommand` on `arn:aws:ec2:*:*:instance/*` conditioned on `aws:ResourceTag/Project=rockport`
  - `ssm:SendCommand` on `arn:aws:ssm:*::document/AWS-RunShellScript` and `arn:aws:ssm:*::document/AWS-StartInteractiveCommand`
  - `ssm:StartSession` on the same instance + documents
  - `ssm:GetCommandInvocation`, `ssm:TerminateSession`, `ssm:DescribeSessions`
  - `ec2:StartInstances`, `ec2:StopInstances` on tagged instance only
  - `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:HeadObject` on `rockport-artifacts-*` and `rockport-video-*`
  - **Explicitly NO**: any `iam:*`, any S3 bucket-level mutate, any Lambda mutate, any CloudTrail mutate, any Budgets mutate, any Bedrock guardrail mutate.
- [ ] **T004** [P] Update `terraform/deployer-policies/iam-ssm.json`:
  - Remove statements `IAMDeployerSelfManage` and `IAMDeployerUserManage` (move to `RockportAdmin`).
  - Replace `DenyNonRockportPolicyAttachment`:
    - Sid → `DenyNonRockportPolicyAttachmentToRockportRoles`
    - Resource → `["arn:aws:iam::*:role/rockport*", "arn:aws:iam::*:role/dlm-lifecycle-*"]`
    - Keep the `StringNotLike` allowlist (Rockport-prefixed + AWS-managed allowed)
  - Add new statement `DenyAttachToInstanceRole`:
    - Effect: Deny
    - Action: `iam:AttachRolePolicy`, `iam:DetachRolePolicy`
    - Resource: `arn:aws:iam::*:role/rockport-instance-role`
- [ ] **T005** [P] Update `terraform/rockport-admin-policy.json`:
  - Verify `ManageDeployerPolicies` already covers `iam:CreatePolicyVersion` etc. on `RockportDeployer*` and `RockportAdmin`. Already present.
  - Add `RockportOperator*Boundary` ARNs to that statement so admin can update boundaries during init.
  - Add `iam:ListPolicies` (deployer-policy audit / `init` idempotency check) — currently denied, hits the `ListPolicies` AccessDenied in the smoke trace.
  - Add `iam:DeleteRolePolicy`, `iam:PutRolePolicy` if not present (for inline policies on operator roles managed by terraform).
  - Add MFA management actions: `iam:ListMFADevices`, `iam:EnableMFADevice`, `iam:DeactivateMFADevice`, `iam:ResyncMFADevice`, `iam:CreateVirtualMFADevice`, `iam:DeleteVirtualMFADevice` against `arn:aws:iam::*:user/rockport-deployer` and `arn:aws:iam::*:mfa/rockport-*` so the admin can recover lost MFA.

### Terraform — operator roles + boundaries
- [ ] **T006** Create `terraform/iam-operator-roles.tf`:
  - `aws_iam_role.operator_readonly` — name `rockport-readonly-role`, trust policy from D5, `MaxSessionDuration=3600`, permissions boundary `aws_iam_policy.operator_readonly_boundary.arn`.
  - `aws_iam_role.operator_runtime_ops` — name `rockport-runtime-ops-role`, same shape, boundary `operator_runtime_ops_boundary`.
  - `aws_iam_role.operator_deploy` — name `rockport-deploy-role`, same shape, boundary `operator_deploy_boundary`.
- [ ] **T007** Add three boundary policies in `terraform/iam-operator-roles.tf`:
  - `aws_iam_policy.operator_readonly_boundary` (name `RockportOperatorReadonlyBoundary`) — same content as `readonly.json`.
  - `aws_iam_policy.operator_runtime_ops_boundary` (name `RockportOperatorRuntimeOpsBoundary`) — same content as `runtime-ops.json`.
  - `aws_iam_policy.operator_deploy_boundary` (name `RockportOperatorDeployBoundary`) — coarse "deployer-class services" allow-list. Allows `ec2:*`, `iam:GetRole/CreateRole/DeleteRole/UpdateAssumeRolePolicy/AttachRolePolicy/DetachRolePolicy/PassRole/CreateInstanceProfile/...` (roles only, no policy/user mutation), `ssm:*`, `s3:*` on `rockport-*` buckets, `lambda:*` on `rockport-*` functions, `logs:*` on `rockport-*` log groups, `cloudwatch:*` on `rockport-*` alarms, `events:*` on `rockport-*` rules, `budgets:*` on `rockport-*` budgets, `dlm:*`, `cloudtrail:*` on `rockport-*` trails, `bedrock:*Guardrail*`, `aws-marketplace:Subscribe`/`ViewSubscriptions`, `sts:*`. Hard-deny `iam:CreatePolicy`, `iam:DeletePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, `iam:SetDefaultPolicyVersion`, `iam:CreateUser`, `iam:DeleteUser`, `iam:AttachUserPolicy`, `iam:DetachUserPolicy`, `iam:CreateAccessKey`, `iam:DeleteAccessKey`. Watch the 6144-byte limit; use `aws_iam_policy_document` with `statement` blocks rather than inline JSON to keep it formatted compactly.
- [ ] **T008** Attach managed policies to roles via `aws_iam_role_policy_attachment`:
  - `readonly.json` (managed policy `RockportOperatorReadonly`) → `operator_readonly`
  - `runtime-ops.json` (managed policy `RockportOperatorRuntimeOps`) → `operator_runtime_ops`
  - `RockportDeployerCompute`, `RockportDeployerIamSsm` (slimmed-down), `RockportDeployerMonitoringStorage` → `operator_deploy`
  - Note: the readonly/runtime-ops JSON files become managed policies via `init` (same upsert path as the existing deployer policies); update `ensure_deployer_access()` in `rockport.sh` to upsert all five (compute + iam-ssm + monitoring-storage + readonly + runtime-ops) but only attach `compute/iam-ssm/monitoring-storage` to the deployer user (deployer keeps the old direct attachments through phase 4 for fallback).
- [ ] **T009** Create `RockportDeployerAssumeRoles` policy as `terraform/deployer-policies/assume-roles.json`:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::*:role/rockport-readonly-role",
        "arn:aws:iam::*:role/rockport-runtime-ops-role",
        "arn:aws:iam::*:role/rockport-deploy-role"
      ],
      "Condition": {
        "Bool": {"aws:MultiFactorAuthPresent": "true"},
        "NumericLessThan": {"aws:MultiFactorAuthAge": "3600"}
      }
    }]
  }
  ```
  Have `init` upsert it (alongside the existing deployer policies) but NOT attach in phase 1.
- [ ] **T010** [P] Update `terraform/outputs.tf` to expose:
  - `operator_readonly_role_arn`
  - `operator_runtime_ops_role_arn`
  - `operator_deploy_role_arn`

### Pre-commit checks
- [ ] **T011** `terraform -chdir=terraform fmt -check -recursive` — must pass.
- [ ] **T012** `cd terraform && terraform init -backend=false && terraform validate` — must pass.
- [ ] **T013** `tflint terraform/` — must pass with no new findings.
- [ ] **T014** `trivy config terraform/` — must pass; new findings get a `.trivyignore` entry only with documented justification.
- [ ] **T015** `checkov -d terraform/ --config-file .checkov.yaml` — must pass; new findings get a `.checkov.yaml` skip with justification.
- [ ] **T016** `shellcheck scripts/*.sh pentest/scripts/*.sh` — must be clean.
- [ ] **T017** `gitleaks protect --staged --config=.gitleaks.toml` — must pass (via pre-commit).
- [ ] **T018** Existing pentest still passes against the live deployment: `pentest/pentest.sh run rockport`.

### Manual review and apply
- [ ] **T019** `unset AWS_PROFILE && ./scripts/rockport.sh init` — picks up updated `rockport-admin-policy.json` and creates `RockportDeployerAssumeRoles` + `RockportOperatorReadonly` + `RockportOperatorRuntimeOps`.
- [ ] **T020** `./scripts/rockport.sh deploy` — interactive `terraform plan` review. Confirm only additions: 3 new operator roles, 3 boundaries, 5 attachments, plus the modified `iam-ssm.json` policy version. Zero deletions of existing user-attached policies.
- [ ] **T021** Apply. Verify each role exists with MFA-gated trust policy:
  ```bash
  for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
    aws iam get-role --role-name "$role" \
      --query '{MaxSession: Role.MaxSessionDuration, Boundary: Role.PermissionsBoundary.PermissionsBoundaryArn, Trust: Role.AssumeRolePolicyDocument}' \
      --output json | jq
  done
  ```

### CI gate
- [ ] **T022** Push branch; verify `validate` workflow goes green.
- [ ] **T023** Cross-project regression check (CRITICAL): from a separate shell with admin creds, run `cd /home/matt/appserver && unset AWS_PROFILE && ./scripts/appserver.sh deploy --plan-only` — Appserver's plan must apply without IAM denies. If it fails, surface the deny ARN before continuing.
- [ ] **T024** Merge phase 1 to main.

**Checkpoint**: Phase 1 done. Long-lived deployer key still works exactly as before. Operator roles exist but have no users attached.

---

## Phase 2 — MFA enrolment + AssumeRole permission for deployer user

### Manual MFA enrolment (operator)
- [ ] **T025** Operator: AWS console → IAM → Users → `rockport-deployer` → Security credentials → Multi-factor authentication → Assign MFA device. Authenticator app, e.g. `rockport-deployer-laptop`. Save the device ARN.
- [ ] **T026** Operator: append to `terraform/.env` (gitignored): `export MFA_SERIAL_NUMBER="arn:aws:iam::<account>:mfa/rockport-deployer-laptop"`. Verify the file is git-ignored: `git check-ignore terraform/.env`.

### Attach AssumeRoles policy to deployer user
- [ ] **T027** Update `ensure_deployer_access()` in `scripts/rockport.sh` to attach `RockportDeployerAssumeRoles` to `rockport-deployer` (idempotent — `attach_iam_policy` handles re-runs). Re-running `init` is the apply step; no terraform change needed because the user attachment lives in `init` (matches the existing pattern for the other three deployer policies).
- [ ] **T028** `unset AWS_PROFILE && ./scripts/rockport.sh init`. Expected output: `Policy attachment .... attached (RockportDeployerAssumeRoles → rockport-deployer)`.
- [ ] **T029** Smoke test (operator):
  ```bash
  source terraform/.env
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile rockport)
  for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
    echo "=== $role ==="
    read -rsp "TOTP code: " CODE; echo
    aws sts assume-role \
      --profile rockport \
      --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
      --role-session-name "smoke-${role##*-}-$(date +%s)" \
      --serial-number "$MFA_SERIAL_NUMBER" \
      --token-code "$CODE" \
      --duration-seconds 3600 \
      --query 'Credentials.{Expiration: Expiration}' --output json
  done
  ```
  Each should return an `Expiration` timestamp ~1 hour out.
- [ ] **T030** Smoke — denied paths:
  - With readonly creds exported: `aws ec2 terminate-instances --instance-ids i-FAKE` → `UnauthorizedOperation`.
  - With readonly creds exported: `aws ssm send-command --document-name AWS-RunShellScript --instance-ids i-FAKE --parameters '{"commands":["whoami"]}'` → `AccessDenied` (verifies SC-006).
  - With deploy creds exported: `aws iam create-policy-version --policy-arn arn:aws:iam::${ACCOUNT}:policy/RockportDeployerCompute --policy-document file://compute.json --set-as-default` → `AccessDenied` (verifies SC-005).
  - With admin creds: attempt to attach `AppserverDeployerCompute` to `appserver-deploy-role` → succeeds (verifies SC-004 / FR-014).

### Pre-commit checks
- [ ] **T031** All phase 1 checks must still pass.

### CI gate + merge
- [ ] **T032** Push, CI green, merge.

**Checkpoint**: Phase 2 done. AssumeRole works manually via CLI. Old long-lived key still works for the broad-permission flow.

---

## Phase 3 — CLI `auth` subcommand + per-subcommand role mapping

### CLI helpers
- [ ] **T033** Add `assume_role()` to `scripts/rockport.sh`:
  - `assume_role <role_name>`
  - Reads `MFA_SERIAL_NUMBER` from `terraform/.env`. Bails with a clear message if unset.
  - Prompts for 6-digit TOTP via `read -rsp` (no echo).
  - Calls `aws sts assume-role --role-arn ... --role-session-name <pattern>_$(date +%s) --serial-number $MFA_SERIAL_NUMBER --token-code <code> --duration-seconds 3600`.
  - Writes returned creds to `~/.aws/credentials` profile `rockport-<role>` via `aws configure set`.
  - Exports `AWS_PROFILE=rockport-<role>`.
  - Session name pattern: `readonly_<task>_<ts>`, `runtime_ops_<task>_<ts>`, `deploy_<task>_<ts>` so CloudTrail (FR-007) can distinguish.
- [ ] **T034** Add `ensure_session_valid_for_role()` helper:
  - Checks if `~/.aws/credentials` has profile `rockport-<role>` AND the session is not expiring within 5 minutes.
  - If valid: just exports `AWS_PROFILE=rockport-<role>`.
  - If invalid: calls `assume_role <role_name>` to refresh.
- [ ] **T035** Add `cmd_auth()` and `cmd_auth_status()` subcommands:
  - `rockport.sh auth` — prompts for role choice (default: readonly); calls `assume_role`.
  - `rockport.sh auth --role <name>` — directly assumes the named role.
  - `rockport.sh auth status` — shows: which roles have valid sessions, time remaining, currently active profile.
- [ ] **T036** Add SUBCOMMAND_ROLE map at the top of `scripts/rockport.sh` per D10. Add CI test in `tests/auth-flow-test.sh` (T040) that asserts every dispatcher subcommand has a SUBCOMMAND_ROLE entry.
- [ ] **T037** Update each `cmd_<name>()` function to call `ensure_session_valid_for_role "${SUBCOMMAND_ROLE[<name>]}"` at entry, before any AWS API calls. Skip when value is `admin` or `meta`.
- [ ] **T038** Update `cmd_status()`:
  - Wrap the `ssm_run` call for instance stats in a function that detects AccessDenied (exit 254 from AWS CLI, or "AccessDenied" / "UnauthorizedOperation" in stderr) and prints `(instance stats require runtime-ops role; rerun with: rockport.sh status --instance)` instead of erroring out.
  - Add `--instance` flag handling. With the flag, dispatch through `status_instance` SUBCOMMAND_ROLE entry (`runtime-ops`); without the flag, default to `readonly`.
- [ ] **T039** Add backwards-compat fallback: if no `rockport-<role>` profile exists AND the old `rockport` profile works, use the old profile. Print a one-time-per-shell deprecation warning to stderr.

### New auth-flow test harness
- [ ] **T040** Create `tests/auth-flow-test.sh`. Mirror the assertion-counter style of `pentest/scripts/*.sh`. Test cases:
  - `assume_role readonly` writes the right profile shape to a temp `~/.aws/credentials` (mock `aws sts assume-role` via a stub on PATH).
  - `ensure_session_valid_for_role` correctly detects expired sessions (mock current time vs. session `Expiration`).
  - `auth status` produces parseable output.
  - The SUBCOMMAND_ROLE map covers every CLI subcommand defined in the dispatcher (regex over the dispatcher case statement vs. SUBCOMMAND_ROLE keys).
  - `cmd_status` gracefully handles AccessDenied from `ssm_run`.
- [ ] **T041** Wire `tests/auth-flow-test.sh` into `.github/workflows/validate.yml` — add a step after `shellcheck` that runs the test.

### Pre-commit + CI checks
- [ ] **T042** All phase 1 checks must still pass.
- [ ] **T043** New: `bash tests/auth-flow-test.sh` must pass.

### Manual smoke testing
- [ ] **T044** Fresh shell: `unset AWS_PROFILE && ./scripts/rockport.sh status` → should prompt for MFA, assume readonly, show status (with the "instance stats require runtime-ops" line). Subsequent calls in same shell should reuse cached session.
- [ ] **T045** `./scripts/rockport.sh status --instance` → escalates to runtime-ops; prompts for MFA on first use; shows full instance stats.
- [ ] **T046** `./scripts/rockport.sh config push` → escalates to runtime-ops; uploads artifact + restarts services via SSM.
- [ ] **T047** `./scripts/rockport.sh deploy` → escalates to deploy; runs terraform apply.
- [ ] **T048** `./scripts/rockport.sh auth status` → shows time remaining for all three sessions.
- [ ] **T049** Verify CloudTrail entries:
  ```bash
  aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole --max-results 10 \
    --query 'Events[].{Time: EventTime, User: Username, Resource: Resources[0].ResourceName}' --output table
  ```
  Should show `readonly_*`, `runtime_ops_*`, `deploy_*` session names.
- [ ] **T050** Run pentest under the new flow: `unset AWS_PROFILE && ./scripts/rockport.sh auth --role readonly && ./pentest/pentest.sh run rockport` — must pass.

### CI gate + merge
- [ ] **T051** Push, CI green, merge.

**Checkpoint**: Phase 3 done. New flow works alongside the old long-lived key.

---

## Phase 4 — Skill documentation + cutover

### Documentation updates
- [ ] **T052** [P] Update `.claude/skills/rockport-ops/SKILL.md` — replace `AWS_PROFILE=rockport` references with `Run ./scripts/rockport.sh auth at the start of a session`. Add a "Permissions you'll have" subsection mapping CLI subcommands to roles.
- [ ] **T053** [P] Update `.claude/skills/pentest/SKILL.md` and `.claude/skills/pentest-review/SKILL.md` similarly. Note that `pentest.sh` now defaults to readonly via `rockport.sh auth --role readonly`.
- [ ] **T054** [P] Update `CLAUDE.md` "Important Notes" with:
  - MFA enrolment step in init flow
  - `--instance` flag on status
  - SUBCOMMAND_ROLE-driven role assumption
  - Cross-project deny scoping
  - Removed-from-deploy-role IAM actions
- [ ] **T055** [P] Update `README.md` "Getting Started" to walk through MFA enrolment + the new auth flow.
- [ ] **T056** [P] Update `terraform/rockport-admin-policy.json` documentation in the inline comments (if any) to explain the IAM-mutation actions are admin-only post-017.

### End-to-end skill tests
- [ ] **T057** Run `/rockport-ops "is rockport healthy"` from a fresh shell. Should use readonly throughout. CloudTrail confirms.
- [ ] **T058** Run `/rockport-ops "show spend"` from a fresh shell. Readonly.
- [ ] **T059** Run `/pentest run` from a fresh shell. Readonly + the auth-bootstrap module's HTTP-only key creation.
- [ ] **T060** Run `./scripts/rockport.sh config push` from a fresh shell. Escalates to runtime-ops.
- [ ] **T061** Run `./scripts/rockport.sh deploy` from a fresh shell. Escalates to deploy.

### Pre-commit + CI checks
- [ ] **T062** All previous checks pass.
- [ ] **T063** Markdown lint clean (or `grep -RnE '<[A-Z]+>' .claude/skills/` to catch placeholder text).

### Soak period
- [ ] **T064** Use the new flow as default for one week. Note any friction or bugs in a working list. Old key remains active as fallback.

### CI gate + merge
- [ ] **T065** Push, CI green, merge.

**Checkpoint**: Phase 4 done. Skills updated. New flow is default. Old key still active for emergencies.

---

## Phase 5 — Decommission long-lived deployer key

### Detach direct policies from deployer user
- [ ] **T066** Update `ensure_deployer_access()` in `scripts/rockport.sh` to detach `RockportDeployerCompute` / `RockportDeployerIamSsm` / `RockportDeployerMonitoringStorage` from `rockport-deployer` (they remain attached to the operator_deploy role via T008 + on `rockport-admin` for emergency). Add a `Policy attachment .... detached` log line for each.
- [ ] **T067** `unset AWS_PROFILE && ./scripts/rockport.sh init`. Expected output: three detach lines.

### Verify the deployer user is now minimal
- [ ] **T068** `aws iam list-attached-user-policies --user-name rockport-deployer` — should show only `RockportDeployerAssumeRoles`.

### Deactivate the long-lived access key
- [ ] **T069** Operator: AWS console → IAM → Users → `rockport-deployer` → Security credentials → Access keys → **Make inactive** (do not delete) the existing key.
- [ ] **T070** Verify: `aws iam list-access-keys --user-name rockport-deployer` shows the key as `Inactive`.

### Remove the CLI fallback
- [ ] **T071** Remove the backwards-compat fallback added in T039.
- [ ] **T072** Remove the deprecation-warning helper.

### Final smoke testing
- [ ] **T073** From a clean shell with no `rockport` profile in `~/.aws/credentials` and no `AWS_PROFILE` set, run every top-level subcommand. Each must prompt for MFA on the first call, work thereafter.
- [ ] **T074** Re-run `bash tests/auth-flow-test.sh` and `pentest/pentest.sh run rockport` — both clean.
- [ ] **T075** Verify CI workflow stays green.

### Documentation finalisation
- [ ] **T076** Update README to remove any mention of the long-lived key flow.
- [ ] **T077** Add a "Migrating from long-lived deployer key" troubleshooting section to README for anyone forking the repo from an old commit.

### CI gate + merge
- [ ] **T078** Push, CI green, merge.

**Checkpoint**: Phase 5 done. Long-lived key inactive. New flow is the only flow.

### One week later
- [ ] **T079** Operator: delete the deactivated access key from `rockport-deployer`. (Manual AWS console step.)

---

## Quality Gates Summary (run at every phase)

Every commit on this branch MUST pass:

1. `terraform -chdir=terraform fmt -check -recursive`
2. `cd terraform && terraform init -backend=false && terraform validate`
3. `tflint terraform/`
4. `trivy config terraform/`
5. `checkov -d terraform/ --config-file .checkov.yaml`
6. `shellcheck scripts/*.sh pentest/scripts/*.sh`
7. `gitleaks protect --staged --config=.gitleaks.toml`
8. `bash tests/auth-flow-test.sh` (from phase 3 onwards)
9. `bash pentest/pentest.sh run rockport` (the manual gate; not in CI but must pass before merge)
10. The full `validate` CI workflow

## Cross-Project Regression Check (run at end of every phase)

Critical safety check — ensures we don't break Appserver:

```bash
# From a separate shell with admin creds
unset AWS_PROFILE
cd /home/matt/appserver && ./scripts/appserver.sh deploy --plan-only
# Plan must succeed. If any IAM AccessDenied, stop and surface the policy ARN.
```

This gate covers SC-004 / FR-014.

## Rollback Cheatsheet

| Phase | If something breaks, do this |
|---|---|
| 1 | `git revert` and re-run `init` + `deploy`. New resources are removed; existing flow unaffected. |
| 2 | Detach `RockportDeployerAssumeRoles` from the deployer user. Old direct policies still grant everything needed. |
| 3 | Revert the CLI changes. Operator's old `rockport` profile still has long-lived key with full perms. |
| 4 | Revert the skill doc changes. CLI fallback still works. |
| 5 | Reactivate the deactivated access key. Re-attach the three direct policies via `init`. Re-add the fallback. |
