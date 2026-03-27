# Feature Specification: OPS - Fix ThrottlingException Masking and Add Missing Deployer IAM Permissions

**Feature Branch**: `014-ops-throttle-iam-fix`
**Created**: 2026-03-27
**Status**: Draft
**Input**: Operational review findings from 2026-03-27 infrastructure activity audit

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Client receives correct HTTP status on rate limiting (Priority: P1)

When a client sends an image or video generation request and Bedrock throttles it (429 ThrottlingException), the client should receive HTTP 429 (not 502) so it can distinguish rate limiting from actual failures and implement proper backoff.

**Why this priority**: This is a correctness bug. Clients currently cannot tell the difference between "slow down" and "something broke," leading to inappropriate error handling. All 5 throttling errors observed on 2026-03-27 were returned as 502.

**Independent Test**: Send rapid-fire image generation requests until Bedrock throttles, verify the sidecar returns HTTP 429 with a Retry-After header.

**Acceptance Scenarios**:

1. **Given** Bedrock returns a ThrottlingException on an image generation request, **When** the sidecar catches the error, **Then** it returns HTTP 429 (not 502) with error type "rate_limit_exceeded" and includes a Retry-After header
2. **Given** Bedrock returns a non-throttling ClientError (e.g., ValidationException), **When** the sidecar catches the error, **Then** it still returns HTTP 502 with error type "upstream_error" (existing behavior preserved)
3. **Given** Bedrock returns a ThrottlingException on a video generation request, **When** the sidecar catches the error, **Then** it returns HTTP 429 with the same format as image generation
4. **Given** a throttled request is logged, **When** an operator reviews logs, **Then** the log entry distinguishes throttling from other errors

---

### User Story 2 - Operator can read Lambda logs and query CloudTrail via deployer role (Priority: P2)

An operator using the deployer IAM role can read Lambda function logs (e.g., idle-shutdown Lambda) and query CloudTrail events for Bedrock API call auditing, enabling operational diagnostics without escalating to admin.

**Why this priority**: During the 2026-03-27 operational review, two diagnostic checks were blocked by missing permissions. The deployer can already create/delete these resources but cannot read from them, which is an inconsistent and impractical permission model.

**Independent Test**: Using the deployer role, run `aws logs filter-log-events` against the idle-shutdown Lambda log group and `aws cloudtrail lookup-events` for Bedrock events. Both should succeed.

**Acceptance Scenarios**:

1. **Given** the deployer IAM role, **When** an operator queries Lambda logs with `logs:FilterLogEvents`, **Then** the request succeeds for rockport Lambda log groups
2. **Given** the deployer IAM role, **When** an operator queries CloudTrail with `cloudtrail:LookupEvents`, **Then** the request succeeds
3. **Given** the deployer IAM role, **When** an operator tries to read Lambda logs for non-rockport log groups, **Then** the request is denied (scoping is preserved)

---

### Edge Cases

- What happens when Bedrock returns a ThrottlingException inside a `start_async_invoke` call (video generation)? The video job should be marked as failed with a throttling-specific error message, and the client gets HTTP 429.
- What happens when boto3 retries exhaust internally (3 attempts) and the final error is still ThrottlingException? The sidecar should still return 429, not 502.
- What happens if `logs:FilterLogEvents` is called on a log group that doesn't exist yet (Lambda hasn't run)? AWS returns ResourceNotFoundException -- this is expected IAM behavior, not a permission issue.
- What happens if `logs:DescribeLogStreams` is needed to list streams before filtering? The deployer should also have this permission scoped to rockport log groups.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Sidecar MUST return HTTP 429 when Bedrock returns a ThrottlingException, across all endpoints in image_api.py (variations, background-removal, outpaint) and video_api.py (start_async_invoke)
- **FR-002**: Sidecar MUST include a `Retry-After` header (in seconds) on 429 responses to guide client backoff. A reasonable default (e.g., 5 seconds) is acceptable since Bedrock does not provide a specific retry-after value
- **FR-003**: Sidecar MUST preserve existing HTTP 502 behavior for all non-throttling ClientError exceptions
- **FR-004**: Sidecar MUST log throttling errors distinctly from other errors (e.g., include "throttled" or "ThrottlingException" in the log message) while maintaining the existing error reference UUID pattern
- **FR-005**: Deployer IAM policy MUST include `logs:FilterLogEvents` scoped to `arn:aws:logs:*:*:log-group:/aws/lambda/rockport-*`
- **FR-006**: Deployer IAM policy MUST include `logs:DescribeLogStreams` scoped to `arn:aws:logs:*:*:log-group:/aws/lambda/rockport-*`
- **FR-007**: Deployer IAM policy MUST include `cloudtrail:LookupEvents` with Resource `*` (this action does not support resource-level restrictions)
- **FR-008**: Video job database record MUST reflect throttling as the failure reason when a ThrottlingException causes job failure

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of Bedrock ThrottlingException errors result in HTTP 429 responses to clients (not 502)
- **SC-002**: All 429 responses include a Retry-After header with a positive integer value
- **SC-003**: Operators using the deployer role can successfully query Lambda logs and CloudTrail events without permission errors
- **SC-004**: All existing smoke tests continue to pass (no regression from error handling changes)
- **SC-005**: Non-throttling Bedrock errors continue to return HTTP 502 (no false positives)
