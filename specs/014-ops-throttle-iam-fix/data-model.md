# Data Model: OPS - ThrottlingException Masking & IAM Permissions

**Date**: 2026-03-27 | **Branch**: `014-ops-throttle-iam-fix`

## Entities

No new entities. This spec modifies behavior of existing entities only.

## Modified Behavior

### HTTP Error Responses (image_api.py, video_api.py)

**Current**: All `ClientError` exceptions → HTTP 502, error type `"upstream_error"`

**New**: `ClientError` with `ThrottlingException` or `TooManyRequestsException` error code → HTTP 429, error type `"rate_limit_exceeded"`, includes `Retry-After: 5` header. All other `ClientError` exceptions → HTTP 502 (unchanged).

429 response body format:
```json
{
  "error": {
    "type": "rate_limit_exceeded",
    "message": "Rate limit exceeded. Please retry after the specified interval. Reference: {error_ref}"
  }
}
```

### Video Job Records (rockport_video_jobs table)

**Current**: Throttling failures recorded with generic message `"Bedrock invocation failed (ref: {error_ref})"`

**New**: Throttling failures recorded with specific message `"Bedrock rate limit exceeded (ref: {error_ref})"`

No schema changes to the table.

### IAM Policy (monitoring-storage.json)

**Current CloudWatchLogs statement actions**: CreateLogGroup, DeleteLogGroup, PutRetentionPolicy, ListTagsForResource, TagResource

**New CloudWatchLogs statement actions**: Add FilterLogEvents, DescribeLogStreams (same resource scope: `arn:aws:logs:*:*:log-group:/aws/lambda/rockport-*`)

**Current CloudTrailDescribe statement actions**: DescribeTrails, GetTrailStatus

**New CloudTrailDescribe statement actions**: Add LookupEvents (same resource scope: `*`)
