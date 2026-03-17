# Tasks: Security Hardening

**Input**: Design documents from `/specs/007-security-hardening/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: No test tasks generated (not explicitly requested). Existing smoke tests validate post-deployment.

**Organization**: Tasks are grouped by user story. Each story modifies independent files and can be implemented and tested separately.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: No setup tasks needed — all changes are edits to existing files in an existing project.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: No foundational/blocking tasks — each user story modifies independent files and can proceed immediately.

**Checkpoint**: All user stories can begin immediately in parallel.

---

## Phase 3: User Story 1 - Restrict IAM Deployer Privileges (Priority: P1) MVP

**Goal**: Prevent the deployer role from attaching AWS-managed policies (e.g., AdministratorAccess) to rockport roles, closing the privilege escalation path.

**Independent Test**: Run `aws iam simulate-principal-policy` with the deployer role ARN, action `iam:AttachRolePolicy`, and `PolicyArn=arn:aws:iam::aws:policy/AdministratorAccess` — should return `implicitDeny` or `explicitDeny`.

### Implementation for User Story 1

- [x] T001 [US1] Add explicit Deny statement to `terraform/deployer-policies/iam-ssm.json` that blocks `iam:AttachRolePolicy` and `iam:DetachRolePolicy` when the policy ARN does not match `arn:aws:iam::*:policy/Rockport*` or `arn:aws:iam::*:policy/rockport*`, using a `StringNotLike` condition on `iam:PolicyARN`
- [x] T002 [US1] Update CLAUDE.md deployer IAM notes to document the new Deny statement and the restricted policy attachment behaviour

**Checkpoint**: Deployer can no longer escalate privileges. Terraform applies that attach rockport-prefixed policies still succeed.

---

## Phase 4: User Story 2 - Add Edge Authentication via Cloudflare Access (Priority: P2)

**Goal**: Authenticate all requests at the Cloudflare edge using a service token before traffic reaches the tunnel.

**Independent Test**: Curl the proxy URL without `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers — should receive 403 from Cloudflare. With headers — should pass through to LiteLLM.

### Implementation for User Story 2

- [x] T003 [US2] Create `terraform/access.tf` with `cloudflare_zero_trust_access_application` (self-hosted, domain = `var.domain`), `cloudflare_zero_trust_access_policy` (service auth, requiring service token), `cloudflare_zero_trust_access_service_token` resources, and any needed variables. Verify that authenticated requests pass through to LiteLLM unmodified (FR-004)
- [x] T004 [US2] Add Terraform outputs for service token Client ID and Client Secret (marked sensitive) in `terraform/access.tf`
- [x] T005 [US2] Add `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers to all curl calls in `scripts/rockport.sh`, reading values from environment variables or Terraform output
- [x] T006 [US2] Add `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers to all curl calls in `tests/smoke-test.sh`, accepting them as additional arguments or environment variables
- [x] T007 [US2] Update the `setup-claude` command in `scripts/rockport.sh` to include `defaultHeaders` with the service token in the Claude Code configuration snippet it outputs
- [x] T008 [US2] Update CLAUDE.md to document the Cloudflare Access requirement, the service token headers, the updated client configuration, and the token rotation procedure (generate new token in Terraform, update clients, revoke old token)

**Checkpoint**: Unauthenticated requests are blocked at the Cloudflare edge. All existing clients work with the added headers.

---

## Phase 5: User Story 3 - Harden Systemd Service Sandboxing (Priority: P3)

**Goal**: Add six missing systemd hardening directives to all three services to reduce blast radius of any service compromise.

**Independent Test**: After pushing config, all three services start and serve requests. `systemd-analyze security` shows improved exposure scores.

### Implementation for User Story 3

- [x] T009 [P] [US3] Add `SystemCallFilter=@system-service`, `PrivateDevices=yes`, `RestrictNamespaces=yes`, `CapabilityBoundingSet=`, `ProtectControlGroups=yes`, and `RestrictSUIDSGID=yes` to the `[Service]` section of `config/litellm.service`
- [x] T010 [P] [US3] Add `SystemCallFilter=@system-service`, `PrivateDevices=yes`, `RestrictNamespaces=yes`, `CapabilityBoundingSet=`, `ProtectControlGroups=yes`, and `RestrictSUIDSGID=yes` to the `[Service]` section of `config/cloudflared.service`
- [x] T011 [P] [US3] Add `SystemCallFilter=@system-service`, `PrivateDevices=yes`, `RestrictNamespaces=yes`, `CapabilityBoundingSet=`, `ProtectControlGroups=yes`, and `RestrictSUIDSGID=yes` to the `[Service]` section of `config/rockport-video.service`

**Checkpoint**: All three services run with tighter sandboxing. Security exposure scores are reduced.

---

## Phase 6: User Story 4 - Switch Database Authentication to SCRAM-SHA-256 (Priority: P4)

**Goal**: Replace md5 with scram-sha-256 for all PostgreSQL client authentication, removing the deprecated method from the stack.

**Independent Test**: On a fresh bootstrap, verify pg_hba.conf contains `scram-sha-256` and not `md5`. Verify LiteLLM connects successfully.

### Implementation for User Story 4

- [x] T012 [P] [US4] Change both `md5` strings to `scram-sha-256` in the pg_hba.conf sed commands in `scripts/bootstrap.sh` (lines 49-50)
- [x] T013 [P] [US4] Add `password_encryption = scram-sha-256` to the postgresql-tuning.conf heredoc in `scripts/bootstrap.sh` (lines 38-44) and to `config/postgresql-tuning.conf`

**Checkpoint**: New instance bootstraps use scram-sha-256. Existing instances are unaffected.

---

## Phase 7: User Story 5 - Improve Idle-Stop Monitoring (Priority: P5)

**Goal**: Add a CloudWatch alarm on Lambda errors and extend the idle check to consider CPU utilisation alongside NetworkIn.

**Independent Test**: Verify the CloudWatch alarm exists via AWS CLI. Review Lambda code to confirm both NetworkIn and CPUUtilization are checked before stopping.

### Implementation for User Story 5

- [x] T014 [US5] Extend the Lambda Python code in `terraform/idle.tf` to also query `CPUUtilization` from `AWS/EC2` namespace and only stop the instance when both NetworkIn < threshold AND CPUUtilization < 10% (see research.md R5 for rationale)
- [x] T015 [US5] Add `aws_cloudwatch_metric_alarm` resource in `terraform/idle.tf` on `AWS/Lambda` namespace, `Errors` metric, `Sum` statistic, threshold 1, evaluation periods 2 (consecutive), with alarm description
- [x] T016 [US5] Update CLAUDE.md idle-stop notes to document the CPU signal and the error alarm

**Checkpoint**: Lambda errors trigger an alarm. High-CPU instances are no longer falsely stopped.

---

## Phase 8: User Story 6 - Fix Video Job Concurrency Race Condition (Priority: P6)

**Goal**: Replace the non-atomic count-then-insert with an advisory-lock-protected transaction.

**Independent Test**: Two concurrent video generation requests from the same key (at the limit) result in exactly one acceptance and one rejection.

### Implementation for User Story 6

- [x] T017 [US6] Add new function `insert_job_if_under_limit` in `sidecar/db.py` that acquires `pg_advisory_xact_lock(hashtext(api_key_hash))`, counts in-progress jobs, and conditionally inserts within a single transaction. Returns the job dict or None if limit reached
- [x] T018 [US6] Update `sidecar/video_api.py` to replace the separate `count_in_progress_jobs` check + `insert_job` call with a single call to `insert_job_if_under_limit`, raising HTTP 429 if None is returned
- [x] T019 [US6] Update CLAUDE.md to remove the TOCTOU accepted risk note and document the advisory lock approach

**Checkpoint**: Concurrent job limit is enforced atomically. No race condition possible.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Final validation across all changes

- [x] T020 Run full smoke test suite (`tests/smoke-test.sh`) and manually verify admin CLI workflows (`rockport.sh status`, `key list`, `spend`) to confirm all existing functionality works after all changes (FR-010)
- [x] T021 Run `terraform validate` and `terraform plan` to verify all Terraform changes are syntactically valid and produce expected diff
- [x] T022 Review all CLAUDE.md updates for consistency and accuracy

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: N/A — no setup tasks
- **Foundational (Phase 2)**: N/A — no foundational tasks
- **User Stories (Phases 3-8)**: All independent — can proceed in any order or in parallel
- **Polish (Phase 9)**: Depends on all user stories being complete

### User Story Dependencies

- **US1 (P1) — IAM**: No dependencies. Single file edit.
- **US2 (P2) — Cloudflare Access**: No dependencies on other stories. Requires Terraform apply before smoke tests can include headers.
- **US3 (P3) — Systemd**: No dependencies. Three parallel file edits.
- **US4 (P4) — PostgreSQL**: No dependencies. Two parallel file edits.
- **US5 (P5) — Lambda**: No dependencies. Single file with Lambda code + alarm resource.
- **US6 (P6) — TOCTOU**: No dependencies. Two file edits (db.py then video_api.py sequential).

### Parallel Opportunities

- **All 6 user stories** can be implemented in parallel (they touch completely independent files)
- **Within US3**: T009, T010, T011 are parallel (three separate service files)
- **Within US4**: T012, T013 are parallel (different files)
- **Within US5**: T014, T015 are sequential (same file)
- **Within US6**: T017, T018 are sequential (T018 depends on T017)

---

## Parallel Example: User Stories 1, 3, 4

```text
# These can all run simultaneously:
Task T001: Edit terraform/deployer-policies/iam-ssm.json (US1)
Task T009: Edit config/litellm.service (US3)
Task T010: Edit config/cloudflared.service (US3)
Task T011: Edit config/rockport-video.service (US3)
Task T012: Edit scripts/bootstrap.sh pg_hba.conf lines (US4)
Task T013: Edit scripts/bootstrap.sh + config/postgresql-tuning.conf (US4)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete T001-T002 (IAM restriction)
2. **STOP and VALIDATE**: Run `aws iam simulate-principal-policy` to verify the Deny works
3. Apply with `terraform apply`

### Incremental Delivery

1. US1 (IAM) → `terraform apply` → validate
2. US4 (PostgreSQL) → commit (takes effect on next fresh bootstrap)
3. US3 (Systemd) → `config push` → verify services restart cleanly
4. US5 (Lambda) → `terraform apply` → verify alarm exists
5. US6 (TOCTOU) → `config push` → verify sidecar restarts
6. US2 (Cloudflare Access) → `terraform apply` → update all clients → verify

### Recommended Order Rationale

US2 (Cloudflare Access) is last because it requires updating all clients simultaneously. All other changes are transparent to clients.

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable
- Commit after each user story phase
- US2 (Cloudflare Access) should be deployed last since it requires client-side changes
- All Terraform changes can be reviewed with `terraform plan` before applying
