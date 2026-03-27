# Tasks: OPS - Fix ThrottlingException Masking & IAM Permissions

**Input**: Design documents from `/specs/014-ops-throttle-iam-fix/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

---

## Phase 1: User Story 1 - Correct HTTP status on rate limiting (Priority: P1)

**Goal**: Bedrock ThrottlingException returns HTTP 429 (not 502) with Retry-After header across all sidecar endpoints

**Independent Test**: Trigger a Bedrock throttle on image generation and verify the client receives HTTP 429 with `Retry-After: 5` header and error type `rate_limit_exceeded`

### Implementation for User Story 1

- [x] T001 [P] [US1] Add ThrottlingException detection to ClientError handler in `sidecar/image_api.py` — check `exc.response["Error"]["Code"]` for `ThrottlingException` or `TooManyRequestsException` in the IMAGE_VARIATION endpoint (~line 280), return HTTP 429 with `Retry-After: 5` header and error type `rate_limit_exceeded` instead of 502. Use FastAPI `HTTPException(status_code=429, headers={"Retry-After": "5"})`. Log with "throttled" keyword. Preserve existing 502 behavior for all other ClientError codes.
- [x] T002 [P] [US1] Add ThrottlingException detection to ClientError handler in `sidecar/image_api.py` — BACKGROUND_REMOVAL endpoint (~line 342), same pattern as T001
- [x] T003 [P] [US1] Add ThrottlingException detection to ClientError handler in `sidecar/image_api.py` — OUTPAINTING endpoint (~line 455), same pattern as T001
- [x] T004 [US1] Add ThrottlingException detection to ClientError handler in `sidecar/video_api.py` — `start_async_invoke` call (~line 744). Same 429 pattern as image endpoints. Additionally, update `db.mark_job_failed()` message to `"Bedrock rate limit exceeded (ref: {error_ref})"` for throttling failures

**Checkpoint**: All 4 ClientError handlers now distinguish throttling from other errors. Clients receive 429 for rate limits, 502 for other failures.

---

## Phase 2: User Story 2 - Deployer IAM read permissions (Priority: P2)

**Goal**: Deployer role can read Lambda logs and query CloudTrail events for operational diagnostics

**Independent Test**: Using `AWS_PROFILE=rockport`, run `aws logs filter-log-events --log-group-name /aws/lambda/rockport-idle-shutdown --limit 1` and `aws cloudtrail lookup-events --max-results 1` — both should succeed

### Implementation for User Story 2

- [x] T005 [US2] Add `logs:FilterLogEvents` and `logs:DescribeLogStreams` to the existing `CloudWatchLogs` statement in `terraform/deployer-policies/monitoring-storage.json` (same resource scope: `arn:aws:logs:*:*:log-group:/aws/lambda/rockport-*`)
- [x] T006 [US2] Add `cloudtrail:LookupEvents` to the existing `CloudTrailDescribe` statement in `terraform/deployer-policies/monitoring-storage.json` (already scoped to `Resource: "*"`)

**Checkpoint**: Deployer role has read access to Lambda logs and CloudTrail events.

---

## Phase 3: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and validation

- [x] T007 Update CLAUDE.md to document that sidecar returns HTTP 429 for Bedrock throttling (add to the error sanitization bullet point)
- [x] T008 Run quickstart.md validation — verify deployment and verification steps are accurate

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (US1)**: No dependencies — can start immediately
- **Phase 2 (US2)**: No dependencies — can start immediately, independent of Phase 1
- **Phase 3 (Polish)**: Depends on Phase 1 and Phase 2 completion

### User Story Dependencies

- **User Story 1 (P1)**: Independent. All 4 handler changes are in different endpoints across 2 files
- **User Story 2 (P2)**: Independent. Single JSON policy file, no relationship to sidecar changes

### Parallel Opportunities

- T001, T002, T003 can all run in parallel (different endpoints in same file, no conflicts between the 3 catch blocks)
- T005 and T006 modify the same file but different statements — execute sequentially
- US1 (T001-T004) and US2 (T005-T006) are fully independent and can run in parallel

---

## Parallel Example: User Story 1

```bash
# Launch all image endpoint fixes together (different catch blocks):
Task: "T001 — IMAGE_VARIATION throttle handling in sidecar/image_api.py"
Task: "T002 — BACKGROUND_REMOVAL throttle handling in sidecar/image_api.py"
Task: "T003 — OUTPAINTING throttle handling in sidecar/image_api.py"

# Then sequentially:
Task: "T004 — Video start_async_invoke throttle handling in sidecar/video_api.py"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete T001-T004: All sidecar throttle handling
2. **STOP and VALIDATE**: Deploy via `config push`, trigger throttling, verify 429 response
3. This alone fixes the bug observed on 2026-03-27

### Full Delivery

1. T001-T004: Sidecar throttle handling (US1)
2. T005-T006: IAM policy updates (US2)
3. T007-T008: Documentation and validation
4. Deploy via `rockport.sh deploy` (IAM) + `config push` (sidecar)

---

## Notes

- T001-T003 modify the same file (image_api.py) but different, non-overlapping catch blocks — safe to parallel
- T005-T006 modify the same file (monitoring-storage.json) — must be sequential
- No new files created. All changes are to existing files
- No bash script changes, so Constitution Principle VI does not apply
- IAM policy size must stay under 6144 bytes — current is ~4.8KB, additions add ~150 bytes
