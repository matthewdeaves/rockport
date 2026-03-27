# Research: OPS - ThrottlingException Masking & IAM Permissions

**Date**: 2026-03-27 | **Branch**: `014-ops-throttle-iam-fix`

## R1: How to detect ThrottlingException in botocore ClientError

**Decision**: Check `exc.response["Error"]["Code"]` for `"ThrottlingException"` or `"TooManyRequestsException"`.

**Rationale**: botocore's `ClientError` wraps the AWS error response. The `Error.Code` field contains the specific error type. Bedrock uses `ThrottlingException` for rate limiting. Some AWS services also use `TooManyRequestsException` for the same concept, so checking both is defensive.

**Alternatives considered**:
- Checking the HTTP status code in `exc.response["ResponseMetadata"]["HTTPStatusCode"]` for 429 — works but less specific, could match other 429 scenarios
- Using `isinstance` checks on specific botocore exceptions — botocore dynamically generates exception classes, making this fragile

## R2: Appropriate Retry-After value for Bedrock throttling

**Decision**: Use `Retry-After: 5` (5 seconds) as a static default.

**Rationale**: Bedrock does not include a Retry-After header in its throttling responses. boto3 already retried 3 times internally with exponential backoff before the error reaches our code, so by the time we return 429, the client should wait longer than the initial backoff. 5 seconds is a reasonable middle ground — short enough not to stall interactive workflows, long enough to let Bedrock quotas recover.

**Alternatives considered**:
- Dynamic calculation based on request rate — over-engineered for this use case
- 1 second — too aggressive given boto3 already exhausted its internal retries
- 10 seconds — too conservative for interactive image generation

## R3: FastAPI HTTPException with custom headers

**Decision**: Use `JSONResponse` directly instead of `HTTPException` to include the `Retry-After` header.

**Rationale**: FastAPI's `HTTPException` supports a `headers` parameter that merges custom headers into the response. This is the cleanest approach — no need to switch away from the existing pattern. Example: `raise HTTPException(status_code=429, detail={...}, headers={"Retry-After": "5"})`.

**Correction**: FastAPI `HTTPException` does support `headers` param natively. Use that — it's simpler than `JSONResponse` and consistent with the existing error handling pattern in the codebase.

## R4: IAM policy size impact

**Decision**: Add 3 actions to monitoring-storage.json without exceeding the 6144-byte limit.

**Rationale**: Current monitoring-storage.json is ~4.8KB. Adding `logs:FilterLogEvents`, `logs:DescribeLogStreams` to the existing CloudWatchLogs statement and a new `cloudtrail:LookupEvents` action to the existing CloudTrailDescribe statement adds approximately 150 bytes, well within the 6144-byte limit.

**Approach**: Add `FilterLogEvents` and `DescribeLogStreams` to the existing `CloudWatchLogs` Sid (same resource scope). Add `LookupEvents` to the existing `CloudTrailDescribe` Sid (already has `Resource: "*"`).

## R5: Video job failure message for throttling

**Decision**: Use a distinct failure message like `"Bedrock rate limit exceeded (ref: {error_ref})"` when marking the video job as failed due to throttling.

**Rationale**: The existing `db.mark_job_failed()` call uses a generic message. Distinguishing throttling failures from other failures in the database helps operators understand failure patterns when querying job history.
