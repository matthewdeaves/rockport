# HANDOFF — Rockport IAM MFA + per-skill scoping (017)

This is the operator's apply checklist for the rollout in `specs/017-iam-mfa-scoping/`. The spec/plan/tasks were drafted on 2026-05-03 ahead of any deployment so the work can be reviewed before any AWS-side change. Nothing in this handoff has been applied yet.

Work top-to-bottom. Stop at any step that produces an unexpected diff or error and surface it before continuing.

## Status as of last session

- ✗ Phase 1–5 implementation: not started. Only the spec docs are written.
- ✗ MFA enrolment on `rockport-deployer`: not done.
- ✗ Operator roles: not yet created in Terraform or AWS.
- ✗ `iam-ssm.json` rebuild (cross-project deny scoping + IAM-mutation removal): not yet committed (see "Pre-flight tactical fix" below for the standalone change recommendation).
- ✓ Cross-project safety known: Appserver 003 detached `RockportDeployerIamSsm` from `rockport-admin` permanently to ship. The current `rockport-admin` attachments include four orphaned `Rockport*` policies that no Rockport infra references (Rockport's deployment is currently destroyed). On next `init` they will be reconciled.

## Pre-flight: read before applying anything

- [ ] Read `specs/017-iam-mfa-scoping/spec.md` end-to-end.
- [ ] Read `specs/017-iam-mfa-scoping/plan.md` (especially Design Decisions D6, D7, D8 — they describe the differences from Appserver 003).
- [ ] Read `appserver/specs/003-iam-mfa-scoping/{spec,plan,HANDOFF}.md` for the original pattern. We mirror it with three deviations: (1) readonly has zero SendCommand, (2) deploy role drops IAM-policy CRUD, (3) the cross-project deny is resource-scoped to Rockport roles only.
- [ ] Confirm you're on `main` and CI is green.

## Pre-flight tactical fix (optional, can ship before phase 1)

The current `terraform/deployer-policies/iam-ssm.json` contains a `Resource: "*"` deny that, when re-attached to `rockport-admin`, will block Appserver deploys again (this is exactly what bit Appserver 003). If you want to defuse that risk before merging the full 017 work:

1. Make the surgical edit described in plan.md / D8 — narrow the deny to `arn:aws:iam::*:role/rockport*` + `arn:aws:iam::*:role/dlm-lifecycle-*` and add `DenyAttachToInstanceRole`.
2. Run `unset AWS_PROFILE && ./scripts/rockport.sh init`. Expected output: `IAM policy ........... updated (RockportDeployerIamSsm)`.
3. Re-attach `RockportDeployerIamSsm` to `rockport-admin`:
   ```bash
   unset AWS_PROFILE
   aws iam attach-user-policy \
     --user-name rockport-admin \
     --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/RockportDeployerIamSsm"
   ```
4. Verify Appserver still deploys: from the appserver checkout, `./scripts/appserver.sh deploy --plan-only` (or whichever no-op command exists). No IAM denies expected.

This is a 1-commit change and ships independently of the main 017 work.

## Bootstrap chicken-egg

When `init` runs in the phase-5-collapsed state (after the rollout), the `rockport-deployer` user has only `RockportDeployerAssumeRoles`. The CLI's strict MFA check (added in phase 3) then blocks `rockport.sh deploy` because the operator roles haven't been created yet via terraform.

Use the escape hatch for the **first** terraform apply only:

```bash
unset AWS_PROFILE
ROCKPORT_AUTH_DISABLED=1 ./scripts/rockport.sh deploy
```

`ROCKPORT_AUTH_DISABLED=1` skips `ensure_session_valid_for_role`. Admin creds (default credential chain) drive the apply. After this run, the operator roles exist and normal `rockport.sh auth` flow works for everything else.

## Cross-project leftovers (cleanup, safe to defer)

`rockport-admin` currently has these Rockport-* policies attached (per `aws iam list-attached-user-policies --user-name rockport-admin` on 2026-05-03):

```
RockportAdmin
RockportDeployerCompute
RockportDeployerMonitoringStorage
RockportDeployerAccess     <-- ORPHAN: not in current code; old name from before 011/014
```

`RockportDeployerIamSsm` is detached (Appserver 003 collision).

After phase 1 ships:

- [ ] Detach `RockportDeployerAccess` (orphan):
  ```bash
  unset AWS_PROFILE
  aws iam detach-user-policy \
    --user-name rockport-admin \
    --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/RockportDeployerAccess"
  aws iam delete-policy \
    --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/RockportDeployerAccess"
  ```
- [ ] Re-attach `RockportDeployerIamSsm` after the deny scoping is in place (via the pre-flight tactical fix above, or as part of phase 1).

## Phase 1 apply — additive: 3 roles + boundaries + escalation tightening

**Plan summary** (expected only — confirm during plan review):
- 3 new `aws_iam_policy` resources (boundaries: readonly, runtime-ops, deploy)
- 3 new `aws_iam_role` resources (operator roles)
- 5 new `aws_iam_role_policy_attachment` resources
- 1 modified `aws_iam_policy` (the `RockportDeployerIamSsm` policy version — drops IAM-mutation statements; replaces deny with resource-scoped version + adds `DenyAttachToInstanceRole`)
- Zero deletions of existing user-attached policies, instance, security group, Cloudflare, S3.

Note: `RockportDeployerIamSsm`, `RockportDeployerCompute`, `RockportDeployerMonitoringStorage`, `RockportDeployerAssumeRoles`, `RockportOperatorReadonly`, and `RockportOperatorRuntimeOps` are managed by `rockport.sh init`, not by Terraform. The plan won't show those policies directly; the file changes ship in this commit and will be picked up next time `init` runs.

Steps:

1. [ ] Run `init` first so the modified `iam-ssm.json` + new `readonly.json` + `runtime-ops.json` + `assume-roles.json` get uploaded as new policy versions, AND the new policies are created:
   ```bash
   unset AWS_PROFILE
   ./scripts/rockport.sh init
   ```
   Expected output includes:
   ```
   IAM policy ........... updated (RockportDeployerIamSsm)
   IAM policy ........... created (RockportDeployerAssumeRoles)
   IAM policy ........... created (RockportOperatorReadonly)
   IAM policy ........... created (RockportOperatorRuntimeOps)
   ```
2. [ ] Plan + apply terraform:
   ```bash
   ./scripts/rockport.sh deploy
   ```
   Watch the plan: confirm only additions to the 3 operator roles + 3 boundaries + 5 attachments. Type `yes` to apply.
3. [ ] Smoke: verify the roles exist and have MFA-gated trust policies:
   ```bash
   for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
     echo "=== $role ==="
     aws iam get-role --role-name "$role" \
       --query '{MaxSession: Role.MaxSessionDuration, Boundary: Role.PermissionsBoundary.PermissionsBoundaryArn, Trust: Role.AssumeRolePolicyDocument}' \
       --output json | jq
   done
   ```
   Each should show `MaxSessionDuration: 3600`, a `PermissionsBoundary` arn, and a trust policy with `aws:MultiFactorAuthPresent` and `aws:MultiFactorAuthAge` conditions.
4. [ ] Cross-project regression — Appserver MUST still deploy:
   ```bash
   cd /home/matt/appserver
   unset AWS_PROFILE
   ./scripts/appserver.sh deploy        # or whichever plan-only mode exists
   ```
   Plan must succeed without IAM denies. If `iam:AttachRolePolicy` denies pop up, stop and inspect the deny ARN — it'll tell you which Rockport policy is over-reaching.

**Rollback if anything looks wrong:** `git revert` the phase-1 commits and re-run `init` + `deploy`. The new resources are purely additive — removing them doesn't affect the still-running deployer flow.

## Phase 2 — MFA enrolment (operator only)

The blocking step. `rockport.sh auth` won't work until MFA is enrolled.

1. [ ] AWS console → IAM → Users → `rockport-deployer` → **Security credentials** tab → **Multi-factor authentication (MFA)** → **Assign MFA device**.
2. [ ] Choose **Authenticator app**. Name it (e.g. `rockport-deployer-laptop`). Scan the QR code into 1Password / Authy / your authenticator. Enter two consecutive 6-digit codes to activate.
3. [ ] Copy the device ARN from the AWS console.
4. [ ] Add it to `terraform/.env` (gitignored, never committed):
   ```bash
   echo 'export MFA_SERIAL_NUMBER="arn:aws:iam::<account>:mfa/rockport-deployer-laptop"' >> terraform/.env
   ```
5. [ ] `git check-ignore terraform/.env` — must print the path (confirms .gitignore covers it).
6. [ ] Smoke — assume each role manually with the AWS CLI:
   ```bash
   source terraform/.env
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile rockport)
   for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
     echo "=== $role ==="
     read -rsp "TOTP code: " CODE; echo
     aws sts assume-role \
       --profile rockport \
       --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
       --role-session-name "smoke_${role##*-}_$(date +%s)" \
       --serial-number "$MFA_SERIAL_NUMBER" \
       --token-code "$CODE" \
       --duration-seconds 3600 \
       --query 'Credentials.{Expiration: Expiration}' --output json
   done
   ```
   Each should return an `Expiration` timestamp ~1 hour out.
7. [ ] Smoke — denied paths. With readonly creds exported:
   ```bash
   aws ec2 terminate-instances --instance-ids i-fake 2>&1 | grep -q "UnauthorizedOperation\|AccessDenied" && echo "ec2:Terminate deny works"
   aws ssm send-command --document-name AWS-RunShellScript --instance-ids i-fake --parameters '{"commands":["whoami"]}' 2>&1 | grep -q "AccessDenied" && echo "ssm:SendCommand deny works (SC-006)"
   ```
8. [ ] Smoke — denied IAM mutation from deploy. With deploy creds exported:
   ```bash
   aws iam create-policy-version --policy-arn "arn:aws:iam::${ACCOUNT}:policy/RockportDeployerCompute" --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' --set-as-default 2>&1 | grep -q "AccessDenied" && echo "iam:CreatePolicyVersion deny works (SC-005)"
   ```

## Phase 3-4 — CLI auth flow + skill docs

No additional terraform apply. The CLI changes are local; the admin-policy refresh rides in via `init`.

1. [ ] (If not already done in phase 1) re-run init so the updated `RockportAdmin` policy (now includes MFA-management actions, IAM-mutation actions, listing actions) propagates:
   ```bash
   unset AWS_PROFILE
   ./scripts/rockport.sh init
   ```
2. [ ] Smoke — auth subcommand from a fresh shell:
   ```bash
   unset AWS_PROFILE
   ./scripts/rockport.sh auth --role readonly
   # Enter TOTP code when prompted.
   ./scripts/rockport.sh auth status
   # Should show readonly active with ~60m remaining.
   ./scripts/rockport.sh status
   # Should reuse the cached readonly session (no MFA prompt). Will print the
   # "instance stats require runtime-ops role" line — that's expected (FR-008).
   ```
3. [ ] Smoke — readonly graceful degradation:
   ```bash
   ./scripts/rockport.sh status
   # Output should include the line "(instance stats require runtime-ops role; rerun with: rockport.sh status --instance)"
   ```
4. [ ] Smoke — escalation prompts on first runtime-ops mutation:
   ```bash
   ./scripts/rockport.sh config push
   # Should prompt for MFA again (different role = different session).
   ```
5. [ ] Smoke — deploy role:
   ```bash
   ./scripts/rockport.sh deploy
   # Should prompt for MFA, assume deploy-role, run terraform apply (no-op plan if everything's already up to date).
   ```
6. [ ] CloudTrail confirmation: each session should produce a distinct `RoleSessionName`:
   ```bash
   aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole --max-results 10 \
     --query 'Events[].{Time: EventTime, User: Username, Resource: Resources[0].ResourceName}' --output table
   ```
   You should see `readonly_*`, `runtime_ops_*`, `deploy_*` session names.
7. [ ] Pentest end-to-end under the new flow:
   ```bash
   unset AWS_PROFILE
   ./scripts/rockport.sh auth --role readonly
   ./pentest/pentest.sh run rockport
   ```
   Must pass — entire pentest runs under readonly.

## Phase 5 — decommission long-lived deployer key

The phase-5 commit changes `rockport.sh init` to detach the three legacy direct-attachments from the deployer user. Re-run init to apply.

1. [ ] Re-run init (idempotent) — it'll detach `RockportDeployerCompute / IamSsm / MonitoringStorage` from the deployer user:
   ```bash
   unset AWS_PROFILE
   ./scripts/rockport.sh init
   ```
   Expected output: three lines like `Policy attachment .... detached (RockportDeployerCompute -> rockport-deployer, phase-5 cutover)`.
2. [ ] Verify the deployer user's policy attachments are minimal:
   ```bash
   aws iam list-attached-user-policies --user-name rockport-deployer
   ```
   Should show ONLY `RockportDeployerAssumeRoles`.
3. [ ] Final clean-shell smoke:
   ```bash
   unset AWS_PROFILE
   rm -rf "$HOME/.aws/cli/cache"
   ./scripts/rockport.sh status
   ```
   Should prompt for MFA, assume readonly, then show status.

### Optional: deactivate + rotate the long-lived deployer access key

The key on disk under the `rockport` profile is now MFA-neutralised — a leaked copy can only call MFA-gated `sts:AssumeRole`. If you want defense-in-depth on top of that:

1. [ ] AWS console → IAM → Users → `rockport-deployer` → Security credentials → Access keys.
2. [ ] **Make inactive** (do not delete) the existing key. The CLI's `assume_role` will start failing immediately because it uses `AWS_PROFILE=rockport` to call sts.
3. [ ] Create a new access key. Update `~/.aws/credentials`:
   ```bash
   aws configure set aws_access_key_id <NEW_KEY> --profile rockport
   aws configure set aws_secret_access_key <NEW_SECRET> --profile rockport
   ```
4. [ ] Re-run smoke: `./scripts/rockport.sh auth --role readonly` should work.
5. [ ] After one week of running on the new key without issues, delete the deactivated key from the console.

## Recovery — lost MFA device

If the TOTP device is lost:

1. Fall back to the admin user (`rockport-admin`) — their long-lived creds remain unaffected.
2. AWS console as admin → IAM → Users → `rockport-deployer` → Security credentials → MFA → **Remove**.
3. Re-enrol via the steps in "Phase 2 — MFA enrolment" above.

The admin user holds `RockportAdmin` which (after phase 4) includes `iam:ListMFADevices / EnableMFADevice / DeactivateMFADevice / ResyncMFADevice / CreateVirtualMFADevice / DeleteVirtualMFADevice`, so the recovery is self-service from the admin profile.

## Final review and merge

- [ ] Re-read the per-phase commits on the branch in order:
  ```bash
  git log main..017-iam-mfa-scoping --oneline
  ```
- [ ] Squash-merge or merge-commit the PR once the smoke checks above all pass.
- [ ] Tick all five phases as done on the PR description.

## Blockers / known issues

None at the time of handoff (the spec only). Local quality gates expected to be green on every phase commit:

- `terraform fmt` / `validate` / `tflint` / `trivy config` / `checkov` (the existing `.checkov.yaml` skip list may need 1-2 additions for the boundary policies — document inline)
- `shellcheck` (scripts + pentest)
- `bash tests/auth-flow-test.sh` — new in phase 3
- `pentest/pentest.sh run rockport` — manual gate
- `gitleaks`

Anticipated spec deviations (record in the per-phase commit messages if they materialise):

- **Phase 1 deploy boundary**: coarse "deployer-class services" allow-list rather than a byte-for-byte mirror of compute + iam-ssm + monitoring-storage (those JSON files combined exceed the 6144-char managed-policy limit). Same compromise Appserver 003 made.
- **Phase 2 attachment path**: `RockportDeployerAssumeRoles` is attached to `rockport-deployer` via `rockport.sh init` (matches the existing pattern for the other deployer policies) rather than via `aws_iam_user_policy_attachment` in terraform — the deployer user itself isn't a terraform-managed resource.
- **Phase 5**: long-lived access key deactivation is optional defense-in-depth, not mandatory. The risk reduction comes from the policy detachment.

## Operator-only steps (not run by Claude)

- T025 — TOTP MFA enrolment via AWS console
- T028 — terraform apply + smoke tests with real TOTP code
- T044–T050 — end-to-end CLI smoke tests
- T057–T061 — full skill end-to-end tests
- T064 — one-week soak period
- T067 / T069 / T079 — phase-5 apply + key deactivation/deletion
