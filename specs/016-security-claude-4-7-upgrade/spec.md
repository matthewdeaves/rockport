# Feature Specification: Security Upgrade and Claude 4.7 Support

**Feature Branch**: `016-security-claude-4-7-upgrade`
**Created**: 2026-04-21
**Status**: Draft
**Input**: User description: Mandatory security upgrade (LiteLLM CVE patch) and support for Anthropic's Claude Opus 4.7 on Bedrock, plus a set of defect fixes and hardening items identified during a research audit.

## Clarifications

### Session 2026-04-21

- Q: What body should the video-sidecar health endpoint return on an unauthenticated call? → A: Minimal JSON `{"detail":"unauthorized"}` with HTTP 401; no per-model or per-region state disclosed. Rationale: matches sidecar's existing 401 responses elsewhere, does not leak reconnaissance data, requires no new authentication pathway.
- Q: What should happen when the admin CLI cannot parse or find the proxy config while deriving the Claude-only allowlist? → A: Fail loudly with a non-zero exit and a clear error message — never fall back to an empty or stale list. Rationale: silent fallback would let operators create "Claude-only" keys with no Claude access, a security-relevant silent failure.
- Q: Should the per-key concurrent-job limit be enforced per-model, per-region, or globally per-key? → A: Globally per `api_key_hash`, counted across every model and region, enforced atomically under the existing advisory lock. Rationale: matches the documented "Per-key concurrent job limit defaults to 3" contract; any finer split would let a key double or triple its documented budget.
- Q: How should the proxy handle Opus 4.7's newly-rejected parameters (`temperature`, `top_p`, `top_k`, legacy thinking options)? → A: Rely on the global `drop_params: true` already in place — no per-model overrides. Rationale: concentrates the compatibility shim in one setting, matches the pattern used for other model-specific parameter drops, avoids per-model config drift.
- Q: Should the pentest sidecar module assertion for `/v1/videos/health` be updated to expect 401 rather than 200 on an anonymous probe? → A: Yes — update the pentest assertion in the same change set so the suite validates the new auth posture rather than flagging it as a regression. Rationale: the pentest suite is a security gate, not a baseline recorder; it should always reflect the intended posture.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Claude Code routing for Opus 4.7 (Priority: P1)

As a developer using Claude Code pointed at the Rockport proxy, I need my tool's current default model identifier (`claude-opus-4-7[1m]`) to route to a real Bedrock model so my sessions work without manual configuration.

**Why this priority**: Without this, every Claude Code session against Rockport fails with an unknown-model error after the next re-deploy. This blocks the primary use case of the proxy.

**Independent Test**: Issue a chat completion to the proxy with `model=claude-opus-4-7[1m]` and receive a successful response referencing a Claude Opus 4.7 generation; a follow-up identical request reports non-zero `cache_read_input_tokens`.

**Acceptance Scenarios**:

1. **Given** a deployed proxy and a valid API key, **When** Claude Code issues a completion request with the default `claude-opus-4-7[1m]` identifier, **Then** the proxy returns a valid 200 response with Claude Opus 4.7 content.
2. **Given** a repeated request with the same system prompt within the cache TTL, **When** the request is made, **Then** the response usage block indicates cached tokens were read.
3. **Given** a Claude-only virtual API key, **When** it is used to request `claude-opus-4-7` or `claude-opus-4-7[1m]`, **Then** the request is permitted (not rejected by the key model allowlist).

---

### User Story 2 - Proxy free of known-exploitable CVEs (Priority: P1)

As an operator of Rockport, I need the proxy process running on the instance to be free of known-exploitable vulnerabilities so that an authenticated client cannot escalate via SQL injection, auth bypass, RCE, or privilege-escalation flaws.

**Why this priority**: The current pinned LiteLLM version carries a SQL-injection on the hot authentication path and five additional high/critical advisories. This is a non-negotiable patch.

**Independent Test**: Query the deployed proxy's version metadata and confirm the reported LiteLLM version is at or above the remediated release; re-run the pentest suite and confirm no new failures.

**Acceptance Scenarios**:

1. **Given** a fresh deploy, **When** the proxy reports its version, **Then** the version is at the patched release (or newer).
2. **Given** the repository dependency scan, **When** CI runs the security-scan job, **Then** no HIGH/CRITICAL advisories are reported for the pinned proxy version.

---

### User Story 3 - Portable infrastructure (no hardcoded domain) (Priority: P2)

As a future operator forking or re-deploying Rockport under a different domain, I need the edge allowlist rules to reference the configured domain variable, not a hardcoded hostname, so the rules actually protect whatever host I deploy to.

**Why this priority**: A hardcoded hostname silently renders the allowlist ineffective on any other domain; defense-in-depth becomes zero-depth. Not critical today because the only live deployment uses the hardcoded host, but it is a correctness defect.

**Independent Test**: Change the `domain` input variable to a new hostname, re-plan the infrastructure, and confirm the allowlist rules reference the new hostname in every place the previous hostname appeared.

**Acceptance Scenarios**:

1. **Given** a terraform plan with a different `domain` value, **When** the plan is generated, **Then** the WAF expression uses the new hostname in all three rules.
2. **Given** a terraform fmt/validate run, **When** the suite executes, **Then** both pass without modification.

---

### User Story 4 - Claude-only keys cover all Claude models without manual updates (Priority: P2)

As an operator creating a Claude-only virtual key, I need the key's allowlist to include every Claude-family model the proxy actually serves, without me having to edit a second file each time a model is added.

**Why this priority**: Today the allowlist is duplicated — once in the proxy config, once in the admin CLI. Silent drift means new Claude models are inaccessible to existing Claude-only keys.

**Independent Test**: Add a new `claude-*` entry to the proxy model configuration, create a new Claude-only key via the CLI, and confirm the key allows the new model (without having separately edited the CLI's hardcoded list).

**Acceptance Scenarios**:

1. **Given** a proxy configuration listing N Claude model entries, **When** the operator creates a Claude-only key, **Then** the key's allowed-models list matches N Claude entries exactly.
2. **Given** a proxy configuration that is missing or malformed, **When** the operator attempts to create a Claude-only key, **Then** the CLI reports a clear error rather than silently using a stale list.

---

### User Story 5 - Health endpoint does not leak internal state to anonymous callers (Priority: P2)

As a security-conscious operator, I need the video-sidecar health endpoint to require authentication so that unauthenticated scanners cannot enumerate which Bedrock regions/models the instance depends on.

**Why this priority**: Defense-in-depth. The endpoint reveals per-region Bedrock availability, which is useful reconnaissance data for an attacker who has bypassed the edge.

**Independent Test**: Issue a GET to the health endpoint without a Bearer token and receive a 401; repeat with a valid virtual key and receive a 200 containing the health payload.

**Acceptance Scenarios**:

1. **Given** no Authorization header, **When** the health endpoint is queried, **Then** the response is an HTTP 401 and contains no per-model or per-region detail.
2. **Given** a valid virtual API key, **When** the health endpoint is queried, **Then** the response is an HTTP 200 or 503 with the full per-model health payload.

---

### User Story 6 - Per-key concurrent-job limit is globally enforced (Priority: P2)

As an operator providing a shared API key with a defined concurrent-job budget, I need the proxy to enforce that budget across all video providers (including both Nova Reel and Luma Ray2), regardless of which region each provider uses.

**Why this priority**: The counter is already cross-model in the current implementation, but there is no regression test asserting the invariant. A future refactor could silently split counters per region, and we would not notice until a customer complained.

**Independent Test**: Submit the maximum allowed concurrent jobs mixing Nova Reel and Ray2 requests under a single key, and verify the N+1th request is rejected irrespective of which provider it targets.

**Acceptance Scenarios**:

1. **Given** the per-key limit is set to N, **When** a key submits N mixed Nova Reel + Ray2 jobs, **Then** an additional request is rejected with the intended limit error.
2. **Given** a second key exists, **When** it submits jobs concurrently, **Then** it is not blocked by the first key's count.

---

### User Story 7 - Cache pricing works for every Claude-family alias (Priority: P3)

As a user consuming Claude Code via any of the aliased model identifiers the proxy exposes, I need prompt caching to be applied consistently so repeated system prompts do not re-bill at the full token rate.

**Why this priority**: Caching is already configured for the canonical Claude names but is missing from some aliases. Fixing this prevents silent cost regressions for clients that happen to hit an alias.

**Independent Test**: Issue the same system prompt twice against each Claude alias and confirm `cache_read_input_tokens > 0` on the second call.

**Acceptance Scenarios**:

1. **Given** a request to a Claude alias, **When** the system prompt is repeated, **Then** the second call reports cached token reuse.

---

### User Story 8 - Dependency patch levels current (Priority: P3)

As an operator running the sidecar, I need the native database-driver dependency at the current patch release so I inherit any upstream hardening published before the release cut.

**Why this priority**: Low risk, low friction, no functional change. Best taken with the other sidecar-affecting changes to minimize deploy cycles.

**Independent Test**: Installed driver version matches the expected patch.

**Acceptance Scenarios**:

1. **Given** a freshly provisioned sidecar, **When** the operator inspects the installed driver version, **Then** it reports the expected patch level.

---

### User Story 9 - Release documentation accurate (Priority: P3)

As a future contributor or operator, I need the project README/CLAUDE documentation to reflect the current model set and the upcoming Bedrock retirement calendar so I can plan capacity and migrations.

**Why this priority**: Stale docs cause time lost debugging imaginary issues and missed retirement deadlines. Low urgency but high downstream value.

**Independent Test**: Read the "Recent Changes" and chat/image/video model sections of the docs and verify they match the configured model set and include the known Bedrock retirement dates.

**Acceptance Scenarios**:

1. **Given** a reader of the docs, **When** they look up which Claude models are supported, **Then** Claude Opus 4.7 is listed.
2. **Given** an operator planning Q2/Q3 work, **When** they check for Bedrock retirements, **Then** the Titan Image v2 (2026-06-30), Nova Canvas v1 (2026-09-30), and Nova Reel v1.1 (2026-09-30) end-of-life dates are documented.

---

### Edge Cases

- **Proxy config malformed or unreadable when deriving Claude list**: The CLI must fail loudly with a clear error rather than fall back silently to an empty or stale list.
- **Opus 4.7 request using parameters the new model now rejects (`temperature`, `top_p`, `top_k`)**: The proxy's existing "drop unsupported parameters" setting handles this without returning an error; no config change is required but the behavior must continue to hold after the LiteLLM bump.
- **Claude Code variant identifiers (`claude-opus-4-7[1m]` with brackets)**: Bracket characters must be preserved through config, routing, CLI key creation, and the admin allowlist — no URL/JSON re-encoding should break them.
- **Fresh deploy after destroy with no existing SSM parameters**: The full deploy path from an empty state must succeed — no step may assume prior state.
- **Health endpoint called by an on-instance probe that does not carry a Bearer token**: Such callers must use the existing LiteLLM `/health` path (already allowlisted) or present a credential; the video-sidecar health endpoint is not intended for anonymous liveness probes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The proxy MUST route requests whose model identifier is `claude-opus-4-7` to the Claude Opus 4.7 Bedrock offering via the EU cross-region inference profile.
- **FR-002**: The proxy MUST route requests whose model identifier is `claude-opus-4-7[1m]` (the literal Claude Code runtime identifier including square brackets) to the same Claude Opus 4.7 Bedrock offering.
- **FR-003**: Both Opus 4.7 entries MUST participate in system-message prompt caching using the existing cache-injection mechanism.
- **FR-004**: The pinned proxy (LiteLLM) version MUST be at or above the release that fixes the currently-known SQL-injection, OIDC bypass, password hash, MCP RCE, prompts-test SSTI, and config-update privilege-escalation advisories.
- **FR-005**: The edge allowlist (WAF) rules MUST reference the configured deployment domain through a variable, not a hardcoded hostname.
- **FR-006**: The admin CLI MUST derive the Claude-only allowlist from the authoritative proxy configuration file at key-creation time, and MUST fail with a clear error if that file cannot be parsed.
- **FR-007**: The video-sidecar health endpoint MUST reject requests lacking a valid API key with an HTTP 401 and MUST NOT disclose per-model or per-region state in the 401 body.
- **FR-008**: The per-key concurrent-job limit MUST count in-progress and pending jobs for that key across all video providers and regions, enforced in a single atomic check-and-insert.
- **FR-009**: Every Claude-family alias entry exposed by the proxy MUST carry the same prompt-caching configuration as its canonical counterpart.
- **FR-010**: The sidecar dependency manifest MUST pin the current patch release of the native PostgreSQL driver, and the corresponding hash-locked file MUST be regenerated to match.
- **FR-011**: The project documentation MUST list Claude Opus 4.7 among supported chat models, reference the updated proxy version in "Recent Changes", and document the known Bedrock model retirement calendar (Titan Image v2: 2026-06-30; Nova Canvas v1 and Nova Reel v1.1: 2026-09-30) so future work can schedule migrations.
- **FR-012**: Existing image/video/chat behavior MUST NOT regress — all current model aliases, pricing lookups, and smoke tests MUST continue to pass.
- **FR-013**: The upgrade MUST be deployable via the existing `deploy` and `upgrade` flows (full fresh deploy, plus rolling restart on an existing instance) without operator intervention between stages.

### Key Entities

- **Proxy configuration**: The authoritative list of model aliases and their routing/caching settings. Source of truth for Claude-family membership used by the admin CLI.
- **Virtual API key**: An access credential with an optional model allowlist. Claude-only keys must reflect the proxy's full Claude-family set automatically.
- **Video job**: A unit of asynchronous work per (key, model, provider). Counted for concurrency enforcement regardless of provider or region.
- **Edge allowlist rule set**: The three WAF expressions that scope every other rule to the deployment domain. Must reference the domain by variable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A Claude Code session connected to the proxy using its default runtime model identifier completes chat-completion calls with a 200 status and non-zero cached input tokens on the second identical request.
- **SC-002**: A deployed proxy reports a version string that includes the CVE-remediated release number; the repository security scans report zero HIGH or CRITICAL advisories for the pinned version.
- **SC-003**: An automated plan run with a changed deployment-domain variable produces WAF rules that reference the new domain in 100% of places the old domain appeared.
- **SC-004**: Creating a Claude-only virtual API key yields an allowed-models array whose Claude entries exactly match the distinct Claude model names present in the proxy configuration at the moment of creation.
- **SC-005**: A request to the video-sidecar health endpoint without a credential returns HTTP 401 and zero bytes of per-model information; a request with a valid credential returns HTTP 200 (or 503 if unhealthy) with the full payload.
- **SC-006**: Submitting the configured maximum concurrent jobs against a single key — mixing Nova Reel and Ray2 in any proportion — results in the (max+1)th request being rejected, while a second key's jobs succeed concurrently.
- **SC-007**: Across every Claude-family model identifier the proxy exposes, a repeated identical system prompt within the cache TTL records non-zero cached input tokens on the second call.
- **SC-008**: The full continuous-integration validation workflow (formatting, infrastructure validation, shell lint, secrets scan, infrastructure security scan, dependency audit, policy scan) passes end-to-end on the change set.
- **SC-009**: A fresh deploy from an empty infrastructure state completes without operator intervention and the existing smoke-test and pentest suites pass against the deployed instance.
- **SC-010**: Project documentation lists Claude Opus 4.7, the updated proxy version in "Recent Changes", and the three Bedrock retirement dates.

### Assumptions

- The latest stable LiteLLM release at feature kickoff is **1.83.7-stable**; it will be used as the pin. If a later patch release appears before cut, the higher patch may be substituted provided it addresses the same advisories and introduces no new breaking config changes relevant to this project.
- Claude Opus 4.7 is available on Bedrock in at least one EU inference profile (`eu.anthropic.claude-opus-4-7`), as confirmed by pre-feature research on 2026-04-21.
- Anthropic's documented Opus 4.7 breaking changes (rejection of `temperature`/`top_p`/`top_k`, adaptive-only thinking) are absorbed by the proxy's existing `drop_params: true` behavior; no per-model overrides are required.
- The Claude-only allowlist is derived via a simple structural scan (grep for `model_name: claude-*` entries) rather than a full YAML parser, to avoid adding a dependency. The scan is considered correct if and only if every Claude model's `model_name` begins with the literal prefix `claude-` — this is already a convention in the file.
- The `amazon.titan-image-generator-v2:0` model is retained in configuration despite its 2026-06-30 Bedrock retirement (operator decision); the retirement date is documented but no removal is scheduled in this feature.
- The existing LiteLLM `/health` endpoint remains unauthenticated and is the path used by external liveness probes; the sidecar's `/v1/videos/health` is a deeper per-model health used only by authenticated operators.
- No new Cloudflare Access service-token or API-key rotation is part of this feature; existing edge-authentication posture is inherited.
