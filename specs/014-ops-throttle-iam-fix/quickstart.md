# Quickstart: OPS - ThrottlingException Masking & IAM Permissions

**Branch**: `014-ops-throttle-iam-fix`

## What Changed

1. **Sidecar error handling**: Bedrock ThrottlingException now returns HTTP 429 (was 502) with `Retry-After: 5` header, in both image and video endpoints
2. **Deployer IAM**: Added read permissions for Lambda logs (`FilterLogEvents`, `DescribeLogStreams`) and CloudTrail events (`LookupEvents`)

## How to Deploy

```bash
# 1. Deploy IAM policy changes
./scripts/rockport.sh deploy

# 2. Push sidecar code changes
./scripts/rockport.sh config push
```

## How to Verify

```bash
# Verify IAM — should succeed with deployer role
AWS_PROFILE=rockport aws logs filter-log-events \
  --log-group-name /aws/lambda/rockport-idle-shutdown \
  --limit 1 --region eu-west-2

AWS_PROFILE=rockport aws cloudtrail lookup-events \
  --max-results 1 --region eu-west-2

# Verify throttle handling — check sidecar logs after image generation
./scripts/rockport.sh logs  # Look for "throttled" in any error entries
```

## Client Impact

- Clients that receive rapid-fire 502 errors on image/video generation may now see 429 instead — this is correct behavior
- Clients should implement exponential backoff when receiving 429, using the `Retry-After` header value as the minimum wait
