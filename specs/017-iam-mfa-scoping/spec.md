# Feature Specification: MFA + Per-Skill IAM Scoping for Rockport Operations

**Feature Branch**: `017-iam-mfa-scoping`
**Created**: 2026-05-03
**Status**: Draft
**Input**: Operator description: "Bring Rockport's IAM up to the same hardening level as Appserver 003. Replace the long-lived `rockport-deployer` access key with MFA-gated short-lived STS sessions across three scoped roles. Avoid the two security findings still outstanding on Appserver."

## Background

Rockport currently uses a single IAM user (`rockport-deployer`) with a long-lived access key on the operator's laptop. Three managed policies (`RockportDeployerCompute`, `RockportDeployerIamSsm`, `RockportDeployerMonitoringStorage`) attach directly to that user and to the calling admin (`rockport-admin`). Every CLI invocation — `status`, `key list`, `deploy`, `destroy`, `config push` — runs with the same broad permissions: full Bedrock infra control, full S3, IAM policy CRUD on `RockportDeployer*`, and `ssm:SendCommand` against the tagged instance via `AWS-RunShellScript` (root-equivalent on the box).

Two changes have made this worse, not better:

1. The same AWS account now also hosts Appserver. `rockport-admin` is the shared admin user. A laptop compromise affects both projects.
2. Appserver shipped its IAM hardening (branch `003-iam-mfa-scoping`, PR #10) and surfaced two findings we should not replicate here:
   - **Finding A** — Appserver's `appserver-readonly-role` was given `ssm:SendCommand` + `AWS-RunShellScript` so that `appserver.sh status` could run `free -m && uptime` on the instance. That makes the "read-only" role effectively root on the box. We will not do this in Rockport.
   - **Finding B** — Appserver's `appserver-deploy-role` inherits `iam:CreatePolicyVersion` against `RockportDeployer*` / `AppserverDeployer*` policies. A compromised deploy session can rewrite its own backing policy, persisting beyond the 1-hour MFA window. We will fix this in Rockport by removing IAM policy mutation from the deploy role entirely (it lives only on `RockportAdmin`, attached to the admin user).

There is also a known cross-project IAM deny collision. The current `RockportDeployerIamSsm` policy contains a `Deny` on `iam:AttachRolePolicy` with `Resource: "*"` and a `StringNotLike` allowlist of `Rockport*` policy ARNs. When attached to `rockport-admin`, it blocks `terraform` from attaching `Appserver*` policies to `appserver-*` roles. Appserver had to detach the policy permanently to ship 003. We will rebuild the deny narrower.

## User Scenarios

### US1 — Operator authenticates with MFA before any Rockport work (P1)

The operator runs `./scripts/rockport.sh auth` once at the start of a session. The CLI prompts for a TOTP code from the MFA device on `rockport-deployer`, exchanges credentials via `sts:AssumeRole`, and writes a 1-hour session to a `~/.aws/credentials` profile. Subsequent CLI calls in the same session use those temporary credentials. After expiry, the next call prompts re-authentication.

**Why P1**: Without this, the rest of the work doesn't reduce the blast radius — long-lived credentials on disk remain the dominant risk and the lever a compromised laptop pulls first.

### US2 — Diagnostic Claude work uses a read-only role by default (P1)

When Claude (or the operator) runs `/rockport-ops` or `/pentest` for triage, the CLI assumes `rockport-readonly-role` instead of the deploy role. CloudTrail shows the role-session-name was `readonly-<task>` for every diagnostic call. If the work needs to mutate something, Claude has to escalate explicitly.

The readonly role has **no** `ssm:SendCommand` of any kind. `cmd_status` falls back to HTTP-only health probes and skips the in-VM resource statistics block when running under readonly (the SSM call returns AccessDenied; the helper degrades gracefully and prints "(instance stats require runtime-ops role)").

**Why P1**: The majority of Rockport's day-to-day work is diagnostic. Defaulting to read-only means most sessions can't issue any destructive AWS call even if a hook somehow let one through. Avoiding `SendCommand`+`AWS-RunShellScript` from readonly closes the "readonly is actually root" trap from Appserver.

### US3 — Runtime operations use a scoped role (P2)

`config push`, `upgrade`, `start`, `stop`, `logs`, full-instance `status` (`status --instance`) assume `rockport-runtime-ops-role` rather than the full deployer. The role grants:

- Everything in readonly
- `ssm:SendCommand` and `ssm:StartSession` on the tagged instance (`aws:ResourceTag/Project=rockport`) with the `AWS-RunShellScript` and `AWS-StartInteractiveCommand` documents — necessary for `config push` to restart services and for `logs` to stream `journalctl`
- `s3:PutObject` / `GetObject` / `DeleteObject` on `rockport-artifacts-*` (for `config push`) and `rockport-video-*` (for video lifecycle ops)
- `ec2:StartInstances` / `ec2:StopInstances` on the tagged instance only

No IAM, no Terraform, no S3 bucket creation/deletion, no CloudTrail mutation, no Lambda CRUD, no Bedrock guardrail CRUD.

**Why P2**: Reduces blast radius further; structurally similar to US2 — implementing US2 first makes US3 mechanical.

### US4 — Full deploys remain available but require explicit role assumption (P2)

`deploy` and `destroy` assume `rockport-deploy-role`, which holds the current deployer's three policies (compute + iam-ssm + monitoring-storage), minus the IAM-policy-mutation actions called out in Finding B. The CLI's auth flow makes this an explicit choice rather than the default. The role assumption logs to CloudTrail with role-session-name `deploy-<task>`.

**Why P2**: Preserves existing capability while making "I'm about to do something destructive" a deliberate step.

### US5 — Bonus: tighten the cross-project deny (P1)

Replace the current account-wide `Deny iam:AttachRolePolicy` on `Resource: "*"` (with a `StringNotLike` policy-ARN allowlist) with a narrowly-scoped deny that only applies when the *role being modified* is a Rockport role. Appserver's IAM operations against `appserver-*` roles will not be affected.

**Why P1**: Cheap to add alongside the boundary work; closes the cross-project collision that forced Appserver to detach `RockportDeployerIamSsm` from the shared admin permanently.

### US6 — Bonus: remove IAM policy mutation from the deploy role (P1)

`iam:CreatePolicy*`, `iam:DeletePolicy*`, `iam:CreatePolicyVersion`, `iam:DeletePolicyVersion`, `iam:SetDefaultPolicyVersion`, `iam:CreateUser`, `iam:DeleteUser`, `iam:AttachUserPolicy`, `iam:DetachUserPolicy`, `iam:CreateAccessKey` are removed from `RockportDeployerIamSsm` and live only on `RockportAdmin` (attached to the admin user). The deploy role can still create/update/delete IAM **roles** named `rockport*` (Terraform manages roles), but cannot modify the **policies** that bound the operator roles.

**Why P1**: Closes Finding B. A compromised deploy session can no longer rewrite its own boundary or re-enable the long-lived deployer key.

## Functional Requirements

- **FR-001**: The system MUST support TOTP-based MFA authentication on the `rockport-deployer` IAM user.
- **FR-002**: All deployer-tier AWS operations MUST go through `sts:AssumeRole` calls conditioned on `aws:MultiFactorAuthPresent=true` and `aws:MultiFactorAuthAge<3600`.
- **FR-003**: STS sessions MUST be limited to 1 hour by role configuration (`MaxSessionDuration=3600`).
- **FR-004**: There MUST be three distinct IAM roles for operational use: `rockport-readonly-role`, `rockport-runtime-ops-role`, `rockport-deploy-role`. Each role's permissions MUST be the minimum needed for its scope.
- **FR-005**: The CLI MUST be able to assume a specific role per subcommand via a `SUBCOMMAND_ROLE` map.
- **FR-006**: The CLI MUST surface session expiry — `auth status` shows time remaining and which role is active.
- **FR-007**: CloudTrail MUST be able to distinguish "which mode of work was active" from the role-session-name (e.g. `readonly_status_<ts>`, `runtime_ops_config_push_<ts>`, `deploy_apply_<ts>`).
- **FR-008**: The readonly role MUST NOT grant `ssm:SendCommand` against any document, including `AWS-RunShellScript`. `cmd_status` MUST degrade gracefully when SendCommand is denied (no instance-stats block; the rest of the report is unaffected).
- **FR-009**: The deploy role MUST NOT grant any of: `iam:CreatePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicy`, `iam:DeletePolicyVersion`, `iam:SetDefaultPolicyVersion`, `iam:CreateUser`, `iam:DeleteUser`, `iam:AttachUserPolicy`, `iam:DetachUserPolicy`, `iam:CreateAccessKey`, `iam:DeleteAccessKey`. These actions live only on the `RockportAdmin` policy attached to the admin user.
- **FR-010**: The cross-project `Deny iam:AttachRolePolicy` MUST be scoped so that it only applies when the modified role is a Rockport role (`arn:aws:iam::*:role/rockport*` or `arn:aws:iam::*:role/dlm-lifecycle-*`). It MUST NOT prevent attachment of non-Rockport policies to non-Rockport roles.
- **FR-011**: All existing CLI subcommands MUST continue to work without behavioural change visible to the operator (other than the auth prompt and the degraded `status` output described in FR-008).
- **FR-012**: The `init` subcommand MUST work via the operator's admin credentials (the `rockport-admin` user with `RockportAdmin` attached) — `init` is the bootstrap path, runs before the operator roles exist, and cannot itself depend on them. The CLI MUST honour a `ROCKPORT_AUTH_DISABLED=1` escape hatch for the first-ever `init` run on a fresh account.
- **FR-013**: The `pentest` toolkit and `/pentest` skill MUST default to the readonly role; modules that need to mutate (e.g. creating temporary API keys) MUST escalate to runtime-ops explicitly.
- **FR-014**: Deployer-side IAM resources MUST share the AWS account cleanly with Appserver: no Rockport policy attached to `rockport-admin` may block IAM operations against `appserver-*` roles, users, or policies.

## Non-Functional Requirements

- **NFR-001 — Recoverability**: If the operator loses their MFA device, the recovery path MUST be a documented IAM-admin manual step (use the `rockport-admin` user's long-lived creds to remove and re-enrol the MFA device on `rockport-deployer`), not a code change.
- **NFR-002 — Backwards compatibility**: During phases 1–3, the existing long-lived access key MUST keep working so the operator is never locked out mid-rollout.
- **NFR-003 — Auditability**: CloudTrail entries for each session MUST identify the role-session-name encoding the operational mode.
- **NFR-004 — Cross-project safety**: Both Appserver and Rockport MUST be able to deploy concurrently from the same admin user without IAM denies from the other project's policies.

## Out of Scope

- Hardware MFA keys (TOTP only for v1). Hardware key support is a future addition.
- Cross-account role assumption.
- AWS SSO / IAM Identity Center integration.
- Splitting `rockport-admin` into a Rockport-only admin user (option mentioned in the operator brief; provisional decision is to keep the shared admin and rely on each project's narrow-scoped denies).
- Replacing `AWS-RunShellScript` with a custom curated SSM document for runtime-ops (could come later as a v2 hardening; for v1, runtime-ops keeps `AWS-RunShellScript` because `config push` legitimately needs arbitrary shell, but readonly does not).
- Lambda-side IAM (the idle-shutdown Lambda role is unrelated to operator roles).
- Replacing the per-subcommand role map with a more granular permission lattice — three roles is the right granularity for a single-operator hobby project.

## Success Criteria

- **SC-001**: After cutover, the operator can complete a full Rockport `deploy` using only MFA-derived STS credentials. No long-lived access keys remain active in `~/.aws/credentials` under the `rockport` profile.
- **SC-002**: A laptop compromise scenario (attacker exfiltrates `~/.aws/credentials`) cannot escalate beyond the active 1-hour session, and cannot use any IAM action without MFA.
- **SC-003**: CloudTrail shows distinct role-session-names for diagnostic, runtime-ops, and deploy operations.
- **SC-004**: Appserver's CLI continues to deploy without modification while Rockport's hardening is in place. No detachments, no manual carve-outs.
- **SC-005**: A successful Rockport deploy session cannot rewrite `RockportDeployerCompute`, `RockportDeployerIamSsm`, `RockportDeployerMonitoringStorage`, the three operator-role boundary policies, or `RockportDeployerAssumeRoles` — verified by attempting `aws iam create-policy-version` against each from the deploy session and confirming `AccessDenied`.
- **SC-006**: A successful Rockport readonly session cannot run any shell on the instance — verified by attempting `aws ssm send-command --document-name AWS-RunShellScript ...` and confirming `AccessDenied`.
- **SC-007**: All quality gates stay green: `terraform fmt -check`, `terraform validate`, `tflint`, `trivy config`, `checkov`, `shellcheck`, `gitleaks`, the `validate` CI workflow, and the existing pentest toolkit.
- **SC-008**: `pentest/` runs end-to-end under the new flow — readonly for diagnostic modules, runtime-ops for the auth-bootstrap module that creates a temporary key.
