# Implementation Plan: Rockport IAM MFA + Per-Skill Scoping

**Branch**: `017-iam-mfa-scoping` | **Date**: 2026-05-03 | **Spec**: [spec.md](spec.md)

## Summary

Replace the current single-deployer-with-long-lived-key model with three IAM roles (readonly, runtime-ops, deploy) assumable from `rockport-deployer` with MFA + 1-hour STS sessions. Default Rockport CLI operations to readonly; escalate explicitly when mutations are needed. Strip IAM-policy mutation from the deploy role. Narrow the cross-project deny so it stops blocking Appserver. Roll out in five phases — each phase is independently safe to merge and revert.

## Technical Context

**Languages**: Terraform (HCL), Bash (CLI + bootstrap), JSON (IAM policy docs)
**Primary AWS APIs**: IAM (`CreateRole`, `AttachRolePolicy`, `PutRolePermissionsBoundary`), STS (`AssumeRole`)
**Storage**: `~/.aws/credentials` for STS sessions; `~/.aws/cli/cache/` for AWS CLI session cache
**Testing**: Existing — `terraform fmt -check`, `terraform validate`, `tflint`, `trivy config`, `checkov`, `shellcheck`, `gitleaks`, `pentest/pentest.sh run rockport`. New — `tests/auth-flow-test.sh` for the CLI auth helpers added in phase 3.
**Target platform**: Operator's laptop (current setup); CI on GitHub Actions (OIDC-driven, untouched by this spec).
**Constraints**:
- Cannot lock the operator out mid-rollout. Old access key must keep working until phase 5.
- Cannot break Appserver's deploy flow at any point — `rockport-admin` is the shared admin user.
- `monitoring-storage.json` is already 5840 bytes (close to the 6144-byte managed-policy limit). The deploy boundary cannot byte-for-byte mirror all three deployer policies; it is a coarser allow-list that still caps the role at deployer-tier services.
- The pentest toolkit must keep working — its target file describes the current attack surface and gets refreshed alongside this work.

## Design Decisions

### D1: Three roles, not one role with conditions

Same reasoning as Appserver 003/D1. Three roles let the IAM evaluation engine enforce the boundary; conditions on session names are too easy to fool.

### D2: AssumeRole, not GetSessionToken

Same reasoning as Appserver 003/D2. The deployer user keeps `sts:AssumeRole` only; all real permissions live on the assumed roles.

### D3: 1-hour `MaxSessionDuration` for all three roles

AWS minimum. Re-auth friction is acceptable for a hobby setup. Bump readonly to 4 hours after the soak week if it bites.

### D4: Default profile is per-subcommand; explicit `--role` flips the active session

Same as Appserver 003/D4. Routine `status` calls reuse the cached readonly session; mutations escalate per-subcommand.

### D5: AssumeRole policy on the deployer user is itself MFA-conditioned

Belt-and-braces. The role's trust policy already requires MFA, but applying the condition at the user level too produces clearer error messages.

```json
{
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
}
```

### D6: Rockport readonly has zero `ssm:SendCommand` (Finding A fix)

Diverges from Appserver 003. The readonly role grants no SSM SendCommand of any kind. `cmd_status` calls `ssm_run` inside a function that catches AccessDenied and prints "(instance stats require runtime-ops role)" without aborting. The rest of `status` (HTTP health probe, model list, LiteLLM `/key/info`) works fine because it goes via the Cloudflare tunnel, not AWS.

The instance-stats block (`free -m && uptime && nproc`) is moved behind a `--instance` flag that escalates to runtime-ops:
- `rockport.sh status` — readonly, no instance stats
- `rockport.sh status --instance` — runtime-ops, includes instance stats

We considered a custom curated SSM document (`Rockport-StatusProbe`) bound to a fixed shell snippet so readonly could safely SendCommand against just that document. Rejected for v1: it introduces a new terraform-managed SSM document, doubles the maintenance surface, and the diagnostic value of `free -m && uptime` over a tunnel is marginal (the LiteLLM `/health` endpoint already indicates whether the box is up).

### D7: Deploy role drops IAM-policy CRUD (Finding B fix)

The current `RockportDeployerIamSsm` policy has `IAMDeployerSelfManage` (CreatePolicyVersion etc. on `RockportDeployer*`) and `IAMDeployerUserManage` (CreateUser/AttachUserPolicy on `rockport-deployer`). Both are removed from the deploy-role attachment path.

These actions still need to run during `init` (the admin bootstrap). They live on `RockportAdmin`, which is attached to the admin user (`rockport-admin`). `init` is documented as an admin-only operation; the deploy role does not need to bootstrap itself.

After cutover, an attacker who pops a deploy session has `terraform apply`-tier reach but cannot:

- Rewrite `RockportDeployerCompute` / `IamSsm` / `MonitoringStorage` / boundaries / `AssumeRoles` to give themselves more
- Create a new `RockportFooBypass` policy and attach it to `rockport-instance-role`
- Create a new long-lived access key on `rockport-deployer`
- Mint a new IAM user

This is the part of the work that materially shrinks the post-MFA blast radius.

### D8: Cross-project deny is Resource-scoped to Rockport roles (FR-010)

Rebuild `DenyNonRockportPolicyAttachment` so it only applies when the modified role is itself a Rockport role:

```json
{
  "Sid": "DenyNonRockportPolicyAttachmentToRockportRoles",
  "Effect": "Deny",
  "Action": ["iam:AttachRolePolicy", "iam:DetachRolePolicy"],
  "Resource": [
    "arn:aws:iam::*:role/rockport*",
    "arn:aws:iam::*:role/dlm-lifecycle-*"
  ],
  "Condition": {
    "StringNotLike": {
      "iam:PolicyARN": [
        "arn:aws:iam::*:policy/Rockport*",
        "arn:aws:iam::*:policy/rockport*",
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
      ]
    }
  }
}
```

The deny only fires if the operator (or a compromised deploy session) tries to attach a non-Rockport policy to a Rockport role. Attaching anything to non-Rockport roles is unaffected — Appserver's deploys work without modification.

We deliberately reject the alternative "widen the allowlist to include `Appserver*`" — it embeds another project's naming convention into Rockport's policy. Resource-scoping is the right primitive.

We also add `DenyAttachToInstanceRole` (belt-and-braces alongside the boundary): an explicit `Deny iam:AttachRolePolicy` / `iam:DetachRolePolicy` on `arn:aws:iam::*:role/rockport-instance-role` regardless of policy ARN. Even if the allowlist somehow lets an attached policy through, the instance role can't be modified by the deployer.

### D9: Three permissions boundaries cap each role's ceiling

Mirrors Appserver 003/T006. Each operator role gets a permissions boundary that defines the maximum it could ever do, even if its inline/managed policies were rewritten:

- `RockportOperatorReadonlyBoundary` — caps readonly at "no mutate, no SendCommand, no IAM"
- `RockportOperatorRuntimeOpsBoundary` — caps runtime-ops at "+ SSM SendCommand on tagged instance + S3 artifacts/video write + EC2 start/stop on tagged instance"
- `RockportOperatorDeployBoundary` — caps deploy at "deployer-class services" (EC2 + IAM-roles-only + SSM + Lambda + Logs + S3 + CloudWatch + Budgets + DLM + EventBridge + Bedrock guardrails + Marketplace + STS); no IAM-policy CRUD, no IAM-user CRUD

Boundaries are managed AWS policies created by Terraform under names `Rockport*`, so they pass the cross-project deny allowlist when attached to operator roles.

### D10: SUBCOMMAND_ROLE map at the top of `rockport.sh`

Following the Appserver pattern. Concrete map:

```bash
declare -A SUBCOMMAND_ROLE=(
  [status]=readonly
  [models]=readonly
  [spend]=readonly
  [monitor]=readonly
  [key_create]=readonly
  [key_list]=readonly
  [key_info]=readonly
  [key_revoke]=readonly
  [setup_claude]=readonly

  [config_push]=runtime-ops
  [upgrade]=runtime-ops
  [start]=runtime-ops
  [stop]=runtime-ops
  [logs]=runtime-ops
  [status_instance]=runtime-ops   # status --instance variant

  [init]=admin                    # uses default credential chain; bypasses the auth flow
  [deploy]=deploy
  [destroy]=deploy
  [auth]=meta                     # the auth subcommand itself doesn't assume a role
)
```

The `admin` and `meta` sentinels are not real role names — they tell the dispatcher to skip `ensure_session_valid_for_role`.

### D11: `init` runs on admin credentials, with an escape hatch for fresh accounts

`init` is the IAM bootstrap. It creates `RockportAdmin`, attaches it to the calling user, creates the three deployer policies, creates `rockport-deployer`, etc. It cannot depend on the operator roles existing (chicken-and-egg).

Resolution: `init` does not enter the auth flow. It uses the default AWS credential chain (operator's admin key, GitHub OIDC, etc.). The CLI dispatcher detects subcommand `init` and bypasses `ensure_session_valid_for_role`.

For the very first run on a fresh account where even `RockportAdmin` doesn't exist yet, the operator passes `ROCKPORT_AUTH_DISABLED=1` to make absolutely sure no role assumption is attempted (mirrors Appserver's `APPSERVER_AUTH_DISABLED=1`). Documented in HANDOFF.

### D12: Pentest toolkit defaults to readonly + escalates explicitly for the auth bootstrap

`pentest/pentest.sh` reads CF-Access headers from `terraform output` (no IAM call) and creates a temporary API key via the LiteLLM `/key/generate` endpoint (HTTP only — uses the master key from SSM, which readonly can read). Both work under readonly.

The auth-bootstrap module currently invokes `aws ssm get-parameter --name /rockport/master-key --with-decryption` (readonly grants `ssm:GetParameter` on `/rockport/*` so this works) and then calls LiteLLM directly. No SSM SendCommand, no IAM mutation. So the entire pentest can run under readonly without modification.

If a future module needs to e.g. start the instance for testing, it can call `rockport.sh start` (which escalates to runtime-ops). No code changes needed in the pentest scripts — the role escalation happens in `rockport.sh`, not `pentest.sh`.

## Phased Rollout

Each phase ships as a separate commit (or PR). No phase breaks the previous phase's behaviour; each can be reverted without forensic work.

### Phase 1 — Additive: roles + boundaries + tightening (LOW RISK)

**What:**

- Create `terraform/deployer-policies/readonly.json` — read-only across EC2 (`Describe*`), DLM (`Get*`), SSM (`GetParameter` on `/rockport/*`, `GetCommandInvocation`, `DescribeInstanceInformation`, `ListCommandInvocations`), CloudWatch (`Get*`/`Describe*`/`List*`), CE (`GetCostAndUsage`), Logs (`Get*`/`FilterLogEvents`), S3 read on `rockport-artifacts-*` / `rockport-tfstate-*` / `rockport-video-*` / `rockport-cloudtrail-*`, CloudTrail (`DescribeTrails`/`GetTrailStatus`/`LookupEvents`), Lambda (`GetFunction*`/`ListFunctions`), Budgets (`DescribeBudget`/`ViewBudget`), Bedrock (`ListFoundationModels`/`GetFoundationModel`), STS `GetCallerIdentity`. **No SSM SendCommand. No IAM. No Modify*.**
- Create `terraform/deployer-policies/runtime-ops.json` — everything in readonly plus `ssm:SendCommand` and `ssm:StartSession` on `arn:aws:ec2:*:*:instance/*` conditioned on `aws:ResourceTag/Project=rockport`, against documents `AWS-RunShellScript` and `AWS-StartInteractiveCommand`; `ssm:GetCommandInvocation` / `TerminateSession` / `DescribeSessions`; `ec2:StartInstances` / `StopInstances` on tagged instance only; `s3:PutObject` / `GetObject` / `DeleteObject` on `rockport-artifacts-*` and `rockport-video-*`.
- Update `terraform/deployer-policies/iam-ssm.json`:
  - Remove `IAMDeployerSelfManage` and `IAMDeployerUserManage` statements (move to `RockportAdmin`; D7).
  - Replace `DenyNonRockportPolicyAttachment` with the resource-scoped version in D8.
  - Add `DenyAttachToInstanceRole` (D8).
- Update `terraform/rockport-admin-policy.json`: ensure it carries the IAM-policy-mutation actions removed from `iam-ssm.json` (it already has most of them; verify gap-free coverage).
- Add three IAM roles in a new `terraform/iam-operator-roles.tf`:
  - `aws_iam_role.operator_readonly` (name `rockport-readonly-role`)
  - `aws_iam_role.operator_runtime_ops` (name `rockport-runtime-ops-role`)
  - `aws_iam_role.operator_deploy` (name `rockport-deploy-role`)
  - Each: trust policy allows `sts:AssumeRole` from `arn:aws:iam::ACCOUNT:user/rockport-deployer`, conditioned on MFA + age. `MaxSessionDuration=3600`. Permissions boundary set.
- Add three boundary policies as `aws_iam_policy` resources:
  - `RockportOperatorReadonlyBoundary`
  - `RockportOperatorRuntimeOpsBoundary`
  - `RockportOperatorDeployBoundary`
- Attach managed policies to roles via `aws_iam_role_policy_attachment`:
  - `readonly.json` → operator_readonly
  - `runtime-ops.json` → operator_runtime_ops
  - `compute.json` + (the slimmed-down) `iam-ssm.json` + `monitoring-storage.json` → operator_deploy
- Add a new managed policy `RockportDeployerAssumeRoles` granting `sts:AssumeRole` on the three role ARNs, MFA-conditioned. Created via Terraform; **NOT** yet attached to the deployer user (phase 2 step).
- Update `terraform/outputs.tf` to expose the three role ARNs.

**What does NOT change:**

- The `rockport-deployer` user keeps its three current managed policies attached directly. Old access key keeps working.
- The `rockport-admin` user keeps `RockportAdmin` (with the merged-in IAM-mutation actions).
- No CLI changes. No skill changes. No `bootstrap.sh` changes.

**Checks (must all pass before merge):**

- `terraform -chdir=terraform fmt -check -recursive`
- `cd terraform && terraform init -backend=false && terraform validate`
- `tflint terraform/`
- `trivy config terraform/`
- `checkov -d terraform/ --config-file .checkov.yaml`
- `shellcheck scripts/*.sh pentest/scripts/*.sh`
- `gitleaks protect --staged --config=.gitleaks.toml`
- Manual `terraform plan` review — only additions to operator-role infra + the iam-ssm/admin-policy modifications. Zero deletions of existing user-attached policies.
- Validate CI workflow green
- `pentest/pentest.sh run rockport` — must still pass under the OLD flow (readonly role not yet wired up).

**Apply:**

```bash
unset AWS_PROFILE   # use admin creds for this first run
./scripts/rockport.sh init     # picks up updated rockport-admin-policy.json + creates RockportDeployerAssumeRoles
./scripts/rockport.sh deploy   # plans + applies the new operator roles + boundaries
```

**Smoke test after apply:**

```bash
for role in rockport-readonly-role rockport-runtime-ops-role rockport-deploy-role; do
  aws iam get-role --role-name "$role" \
    --query '{MaxSession: Role.MaxSessionDuration, Boundary: Role.PermissionsBoundary.PermissionsBoundaryArn, Trust: Role.AssumeRolePolicyDocument}' \
    --output json | jq
done
```

Each role should show `MaxSessionDuration=3600`, a `PermissionsBoundary` ARN, and a trust policy with `aws:MultiFactorAuthPresent` + `aws:MultiFactorAuthAge` conditions.

**Rollback:** `git revert` and re-run `init` + `deploy`. New resources are purely additive — removing them doesn't affect the still-running deployer flow.

### Phase 2 — MFA enrolment + AssumeRole policy on deployer user (LOW RISK)

**What:**

- Operator manually enrols a TOTP MFA device on `rockport-deployer` (AWS console or `aws iam enable-mfa-device`). Save the device ARN.
- Add the device ARN to `terraform/.env` (gitignored): `export MFA_SERIAL_NUMBER="arn:aws:iam::ACCOUNT:mfa/rockport-deployer-laptop"`.
- Update `rockport.sh init` to also attach `RockportDeployerAssumeRoles` to the `rockport-deployer` user (idempotent — `attach_iam_policy` already handles existing attachments).
- Re-run `init`. The new policy attachment is the only change.
- Verify by hand:
  - `aws sts assume-role --role-arn ... --serial-number ... --token-code ... --role-session-name smoke` returns 1-hour creds for each role.
  - With readonly creds exported: `aws ec2 describe-instances` works; `aws ec2 terminate-instances --instance-ids i-fake` returns `UnauthorizedOperation`.
  - With readonly creds exported: `aws ssm send-command --document-name AWS-RunShellScript ...` returns `AccessDenied` (verifies FR-008 / SC-006).
  - With deploy creds exported: `aws iam create-policy-version --policy-arn arn:aws:iam::ACCOUNT:policy/RockportDeployerCompute ...` returns `AccessDenied` (verifies FR-009 / SC-005).

**What does NOT change:**

- `rockport-deployer` STILL has the three direct managed policies. The new AssumeRole policy is additive. Operator can still use the old long-lived key for any work.
- CLI unchanged.

**Checks:** all phase 1 checks, plus the manual smoke above.

**Rollback:** detach `RockportDeployerAssumeRoles` from `rockport-deployer`. Old key flow continues unchanged.

### Phase 3 — CLI `auth` subcommand + per-subcommand role mapping (MEDIUM RISK)

**What:**

- Add `assume_role()`, `ensure_session_valid_for_role()`, and `cmd_auth()` helpers to `scripts/rockport.sh`. Same shape as Appserver's `scripts/appserver.sh`. Reads `MFA_SERIAL_NUMBER` from `terraform/.env`. Prompts for TOTP via `read -s`. Calls `aws sts assume-role`. Writes creds to `~/.aws/credentials` profile `rockport-<role>`. Exports `AWS_PROFILE`.
- Add the `SUBCOMMAND_ROLE` map (D10).
- Update each `cmd_<name>()` function to call `ensure_session_valid_for_role "${SUBCOMMAND_ROLE[<name>]}"` at entry, before any AWS API calls. Skip the call when the value is `admin` or `meta`.
- Add `cmd_auth_status()` showing time remaining for each cached role and which is currently active.
- Update `cmd_status()` to:
  - Call `ssm_run` inside a wrapper that detects `AccessDenied` and prints `(instance stats require runtime-ops role; run rockport.sh status --instance for the full report)`.
  - Add `--instance` flag that maps to the `status_instance` SUBCOMMAND_ROLE entry (`runtime-ops`).
- Add backwards-compat fallback: if no `rockport-<role>` profile exists AND the old `rockport` profile works, use the old profile with a one-time deprecation warning per session. Removed in phase 5.
- Add `tests/auth-flow-test.sh` (mirrors `appserver/tests/auth-flow-test.sh`):
  - Mocks `aws sts assume-role` (canned JSON).
  - Asserts `assume_role readonly` writes the right profile shape to a temp `~/.aws/credentials`.
  - Asserts `ensure_session_valid_for_role` correctly detects expired sessions.
  - Asserts `auth status` produces parseable output.
  - Asserts the SUBCOMMAND_ROLE map covers every CLI subcommand defined in the dispatcher.
- Wire `tests/auth-flow-test.sh` into `.github/workflows/validate.yml`.

**What does NOT change:**

- AWS-side: nothing changes from phase 2.
- Skills: still document `AWS_PROFILE=rockport`, but the CLI handles the new flow under the hood for now (cleanup is phase 4).
- `bootstrap.sh` / sidecar / LiteLLM config: untouched.

**Checks:** all phase 1 checks plus:

- `bash tests/auth-flow-test.sh` clean
- Manual smoke walkthrough (each role); see HANDOFF.md
- `pentest/pentest.sh run rockport` end-to-end under the new flow (should default to readonly via the SUBCOMMAND_ROLE wiring on the wrapper script)

**Rollback:** revert the CLI changes; old `rockport` profile flow works unchanged.

### Phase 4 — Skill documentation + cutover (HIGHER RISK)

**What:**

- Update `.claude/skills/rockport-ops/SKILL.md` (or the equivalent for the project — replace `AWS_PROFILE=rockport` references with "run `./scripts/rockport.sh auth` at the start of a session; the CLI handles role selection per subcommand").
- Update `.claude/skills/pentest/SKILL.md` and `.claude/skills/pentest-review/SKILL.md` similarly. Note that `pentest.sh` runs entirely under readonly.
- Update `CLAUDE.md` "Important Notes" with the new auth flow, MFA enrolment step, and the `--instance` flag for full `status`.
- Update `README.md` "Getting Started" to walk through MFA enrolment.
- Update `docs/rockport_architecture_overview.svg` if it currently shows the deployer key flow (probably doesn't — verify).
- End-to-end skill tests:
  - `/rockport-ops "is rockport healthy"` — must succeed under readonly
  - `/rockport-ops "show spend"` — readonly
  - `/pentest run` — full pentest under readonly + the auth-bootstrap module
  - `./scripts/rockport.sh config push` — escalates to runtime-ops, deploys
  - `./scripts/rockport.sh deploy` — escalates to deploy, terraform apply

**Checks:** all previous phases plus:

- Markdown lint clean (or `grep -RnE '<[A-Z]+>' .claude/skills/` for stray placeholder text)
- Manually verify CloudTrail shows distinct role-session-names
- Soak for a week (or whatever feels right): use the new flow as default; old key remains active as fallback

**Rollback:** revert the skill doc changes; CLI fallback to old key still works.

### Phase 5 — Decommission long-lived deployer key (FINAL CUTOVER)

**What:**

- Update `rockport.sh init` to detach `RockportDeployerCompute` / `IamSsm` / `MonitoringStorage` from the `rockport-deployer` user (they remain attached to operator_deploy role). They also stay attached to `rockport-admin` so that admin emergency direct-deploys still work without going through the operator roles.
- Re-run `init`. Plan should show three policy detachments from the deployer user only.
- Verify: `aws iam list-attached-user-policies --user-name rockport-deployer` shows only `RockportDeployerAssumeRoles`.
- Operator: in AWS console, **deactivate** (not delete) the long-lived deployer access key.
- Remove the backwards-compat fallback added in phase 3.
- Remove the deprecation-warning helper.
- Final smoke: every CLI subcommand from a clean shell with no `rockport` profile in `~/.aws/credentials` and no `AWS_PROFILE` set.

**One week later:** delete the deactivated access key.

**Rollback:** reactivate the access key. Re-attach the three policies via `init`. Re-add the CLI fallback. (Last-resort path; a clean rollback at this point implies something serious went wrong.)

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Operator loses MFA device mid-rollout | `RockportAdmin` policy on `rockport-admin` is the recovery lever; can re-enrol MFA via console |
| Phase 3 CLI bug breaks all CLI calls | Old long-lived key remains active through phase 4; operator can `unset AWS_PROFILE && export AWS_ACCESS_KEY_ID=...` as fallback |
| MFA-conditioned trust policy applied before MFA enabled — operator locked out | Phase 2 enrols MFA before phase 1's role trust policies become load-bearing (deployer user still has direct policies through phase 4) |
| `tflint` / `trivy` / `checkov` flag new IAM resources | Address each finding before merge; `.checkov.yaml` skip list extended only with documented justification (existing pattern) |
| Pentest toolkit breaks because some module needs SendCommand | Identify in phase 3 smoke; either escalate that module via `rockport.sh <subcommand>` (which goes through SUBCOMMAND_ROLE) or update it to read via a different path. Documented as a phase-4 acceptance step |
| `monitoring-storage.json` is at 5840 bytes; deploy boundary mirror would exceed limit | The deploy boundary is intentionally coarser (deployer-class services) — same compromise Appserver 003 made (recorded in their tasks.md spec deviations) |
| Cross-project deny still bites somewhere we haven't anticipated | Phase 1 smoke includes a deliberate test: with admin creds, attempt to attach `AppserverDeployerCompute` to `appserver-deploy-role` — must succeed |
| `rockport-admin` accumulates more responsibilities (Rockport + Appserver admin) | Tracked as out-of-scope; revisit in a future spec if the shared admin becomes a problem |

## Open Questions

- **Q1**: Should the readonly role have `MaxSessionDuration=14400` (4 hours) instead of 3600 to reduce MFA prompts during long Claude diagnostic sessions? **Provisional**: Start at 1 hour for all three; bump readonly after a soak week if the friction proves real.
- **Q2**: Should the admin user (`rockport-admin`) lose the directly-attached deployer policies during phase 5? **Provisional**: No — keeping them on admin preserves the emergency direct-deploy path. The blast radius reduction comes from removing them from `rockport-deployer`, not from `rockport-admin`. (Revisit if the laptop's admin creds prove to be the real risk vector.)
- **Q3**: Should hardware MFA (FIDO2) be supported in v1? **Decision**: No — TOTP only for v1 (FR-001). Hardware key support is a future spec.
- **Q4**: Should the curated `Rockport-StatusProbe` SSM document idea (D6 alternative) be revisited as a v2 hardening that gives readonly back the instance-stats block? **Provisional**: Track as out-of-scope; only worth the maintenance burden if `--instance` proves to be reached for daily.
- **Q5**: Should we split `rockport-admin` from `appserver-admin` cleanly (separate users), or keep the shared admin? **Provisional**: Keep shared. The cross-project deny scoping (D8) makes the technical case for splitting weaker. Revisit if a future incident shows the shared admin is a blast-radius bottleneck.
