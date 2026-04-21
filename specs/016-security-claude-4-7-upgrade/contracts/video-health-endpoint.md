# Contract: `/v1/videos/health`

## Before (current behavior)

- **Method**: `GET`
- **Auth**: none
- **Responses**:
  - `200 OK` — full payload: `{ "status": "healthy", "database": "connected|disconnected", "models": { "<name>": {"status": "healthy|unavailable", "region": "<aws-region>"} } }`
  - `503 Service Unavailable` — same shape, when database or all models unreachable

## After (this feature)

- **Method**: `GET`
- **Auth**: required — Bearer API key via `Authorization: Bearer sk-…`
- **Responses**:
  - `401 Unauthorized` — `{"detail":"unauthorized"}` — when no or invalid credential. **Body MUST NOT include `status`, `database`, `models`, region names, or model names.**
  - `200 OK` — unchanged payload (see above) when credential is valid and service is healthy.
  - `503 Service Unavailable` — unchanged payload when credential is valid and service is degraded.

## Rationale

- The per-region payload is useful reconnaissance data for an attacker. Closing the anonymous read removes that leak.
- Matches the existing auth story of every other sidecar endpoint (single auth path, no new secrets).

## Backwards-compatibility note

- Any client or monitoring system currently polling `/v1/videos/health` anonymously will begin receiving 401s. Remediation: have the monitor carry a scoped virtual API key.
- LiteLLM's unauthenticated `/health` endpoint (port 4000) remains available for anonymous liveness probes and is unaffected by this change.

## Pentest suite

- `pentest/scripts/sidecar.sh` is updated in the same change set so the unauth probe expects `401` rather than `200`. The suite should continue to PASS; the assertion change is a posture realignment, not a new finding.
