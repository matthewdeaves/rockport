# Phase 0 — Research

## Scope

All Technical Context items have concrete decisions; no `NEEDS CLARIFICATION` markers remained after Clarifications. This document records the decisions with their rationale and the alternatives weighed, so future readers understand *why*, not just *what*.

---

## Decision 1 — LiteLLM pin: 1.82.6 → 1.83.7

**Decision**: Pin `litellm_version` to `1.83.7` (stable tag) in `terraform/variables.tf`.

**Rationale**:

- `1.82.6` carries six known-exploitable advisories, most critically **GHSA-r75f-5x8p-qvmc** (SQL injection on the API-key verification path, on the request hot path for every authenticated call). The remaining five (OIDC bypass, unsalted-SHA-256 password hash, MCP RCE, `/prompts/test` SSTI, `/config/update` privilege escalation) are partially mitigated by the Cloudflare WAF allowlist but the SQL injection is not.
- `1.83.7` is the current latest `-stable` tag; `-nightly` tags exist at 1.83.8 / 1.83.9 / 1.83.10 but are explicitly not stable.
- No YAML config keys currently in `config/litellm-config.yaml` are deprecated or renamed in the 1.82 → 1.83 interval (`cache_control_injection_points`, `guardrails`, `drop_params`, `modify_params`, `disable_admin_ui`, `default_max_internal_user_budget`, `default_key_generate_params` all unchanged).
- Prisma client version (0.11.0) is unchanged by this bump.
- Positive side-effect: PR #25517 corrects a Bedrock-Claude cache-token double-count in the streaming usage block, improving spend-tracking accuracy for our `cache_control_injection_points` config.

**Alternatives considered**:

- **Stay at 1.82.6**: Rejected. The SQL injection is on the authenticated request path — any exposed virtual key can be used to exploit it.
- **`>= 1.83.7` range pin**: Rejected. Reproducible deploys require an exact pin.
- **Jump to a 1.83.x nightly**: Rejected. Nightlies skip stability gating.
- **Jump to a hypothetical 1.84.x**: No 1.84 release exists at the time of feature cut.

---

## Decision 2 — Claude Opus 4.7 on Bedrock (EU profile) + `[1m]` alias

**Decision**: Add two entries to `config/litellm-config.yaml`:

1. `model_name: claude-opus-4-7` → `bedrock/eu.anthropic.claude-opus-4-7`
2. `model_name: claude-opus-4-7[1m]` (literal brackets) → same underlying model

Both entries include the same `cache_control_injection_points` block as the existing Opus 4.6 entry. Both rely on the file-level `drop_params: true` to absorb Opus 4.7's rejection of `temperature`, `top_p`, `top_k`, and legacy `thinking.enabled`/`budget_tokens`.

**Rationale**:

- Claude Opus 4.7 launched on Bedrock 2026-04-16 (announced in AWS What's New; model card published). EU cross-region inference profile is listed.
- Claude Code's current runtime model identifier is literally `claude-opus-4-7[1m]` (the 1M-context variant). Without the alias, every Claude Code session pointed at Rockport would 404 after re-deploy.
- Keeping both names live lets us serve curl / OpenAI SDK users with the clean `claude-opus-4-7` identifier and Claude Code with its native identifier, without divergence.
- Cache injection on both entries keeps cost parity across identifiers.

**Alternatives considered**:

- **Only the canonical name, rely on Claude Code users overriding the model**: Rejected. Requires every user to edit their Claude-Code config, creating a flag day.
- **A `model_group` aliasing rule**: Rejected. LiteLLM already supports multiple `model_name` entries sharing the same `model` target with different client-facing names — simpler than a group.
- **Adding per-model `drop_params: true` instead of relying on the global**: Rejected. Global already covers this; per-model would be redundant config drift.

---

## Decision 3 — WAF: replace `llm.matthewdeaves.com` with `${var.domain}`

**Decision**: Three string replacements in `terraform/waf.tf` (lines 28, 34, 42). Use `${var.domain}` interpolation in the expression.

**Rationale**:

- `var.domain` already exists in `terraform/variables.tf` (line 12) and is validated with a regex.
- Hardcoding makes the WAF rules silently ineffective on any other domain (they would match no requests, leaving the allowlist inert).
- This is the smallest correctness fix possible; no rule restructure.

**Alternatives considered**:

- **A `locals { waf_host = var.domain }` indirection**: Rejected. No reuse elsewhere; adds nothing.

---

## Decision 4 — Claude-only allowlist: grep-derived, fail-loud

**Decision**: New helper `claude_models()` in `scripts/rockport.sh`:

```bash
claude_models() {
  local config_file="$CONFIG_DIR/litellm-config.yaml"
  [ -r "$config_file" ] || die "Cannot read $config_file"
  local models
  models=$(grep -E '^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*claude-' "$config_file" \
             | sed -E 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$models" ] || die "No claude-* model_name entries in $config_file"
  # Emit JSON array, preserving literal characters (e.g. brackets in claude-opus-4-7[1m])
  printf '%s\n' "$models" | jq -R . | jq -s -c .
}
```

**Rationale**:

- Existing CLI helpers already use `jq` — no new dependency.
- The YAML convention in the file is one `- model_name: …` line per entry, always indented two spaces — a regex match is robust enough without pulling in a full YAML parser.
- The JSON array output is the exact shape `/key/generate`'s `models` field expects.
- Fail-loud semantics (die on missing file or zero matches) prevents silent creation of "Claude-only" keys with no Claude access, which would be a security-relevant silent failure.

**Alternatives considered**:

- **Installing `yq` and doing a real YAML parse**: Rejected — adds a dependency for marginal robustness. If the file convention ever changes, we notice via smoke-test failures, not silent list drift.
- **Keeping the hardcoded `CLAUDE_MODELS` variable and updating it manually**: Rejected — this was the original defect. The whole point of this feature story is to eliminate the drift.
- **Calling the running proxy's `/v1/models`**: Rejected — coupling key creation to a running proxy makes cold deploys ordering-sensitive (key creation would block on proxy boot) and means misconfigurations are caught later than YAML parsing would catch them.

---

## Decision 5 — Video-sidecar health endpoint: require auth

**Decision**: Add `auth: dict = Depends(authenticate)` to the `/v1/videos/health` handler in `sidecar/video_api.py`. Unauthenticated callers receive the sidecar's standard 401. The 200/503 response shape for authenticated callers is unchanged.

**Rationale**:

- The existing `authenticate` dependency is already used by every mutating video endpoint — reuses the exact same auth path, so no new code to review.
- The health endpoint reveals per-region Bedrock availability, useful reconnaissance data if an attacker ever bypasses the edge.
- Matches the "single auth model, smallest surface" posture chosen in Clarifications.

**Alternatives considered**:

- **Add a separate health-only token**: Rejected — adds a new secret to manage.
- **IP allowlist via Cloudflare Access**: Rejected — the sidecar cannot verify the edge header reliably from inside; doubling up adds complexity with no win.
- **Leave open but redact per-region detail**: Rejected — the endpoint's value *is* the per-region detail for operators; redacting it defeats the purpose.

---

## Decision 6 — Concurrent-job limit: cross-model by `api_key_hash`

**Decision**: Document the existing SQL behavior with a code comment in `sidecar/db.py` adjacent to the `SELECT COUNT(*) … WHERE api_key_hash = %s AND status IN ('pending', 'in_progress')` query. No query change — the query is already correct.

**Rationale**:

- The existing query counts across all models per key. A future refactor that inadvertently added a `model = %s` predicate would silently double the intended budget without failing any test. A comment is the cheapest safeguard.
- Adding a regression test would require provisioning multiple concurrent video slots in CI, which is prohibitive; the comment + pentest-suite observability is the right level.

**Alternatives considered**:

- **Adding an integration test using stub Bedrock**: Rejected — would require mocking the Bedrock async-invoke surface at a level this project has consciously avoided (LiteLLM-first, no custom middleware).

---

## Decision 7 — Cache injection on every Claude-family alias

**Decision**: Ensure every `model_name: claude-*` entry carries the same cache block:

```yaml
cache_control_injection_points:
  - location: message
    role: system
```

**Rationale**:

- Prompt-caching economics apply per-entry: if an alias routes to Bedrock without the injection, the first repeated system prompt does not register a cache hit, and spend regresses silently.
- The config file already follows this convention for canonical names; this feature extends it to any alias entry that is missing it (e.g. `claude-sonnet-4-5-20250929`, `claude-opus-4-5-20251101`).

**Alternatives considered**:

- **Using LiteLLM's global cache config** (if such a thing exists at the file level): Not supported by the LiteLLM config schema for Bedrock cachePoint translation. Per-entry is required.

---

## Decision 8 — psycopg2-binary 2.9.11 → 2.9.12

**Decision**: Bump in `sidecar/requirements.txt`; regenerate `sidecar/requirements.lock` via `pip-compile --generate-hashes`.

**Rationale**:

- 2.9.12 is a patch release (published 2026-04-20). No API changes. Keeps the dependency current.
- The lock is already hash-pinned — regenerating preserves supply-chain integrity.

**Alternatives considered**:

- **Skip**: Rejected — we are already touching the sidecar; rolling in the free patch now saves a future deploy cycle.

---

## Decision 9 — Keep `amazon.titan-image-generator-v2:0` despite 2026-06-30 EOL

**Decision**: Leave the entry in place. Document the EOL date in `CLAUDE.md`'s "Bedrock retirement calendar" subsection.

**Rationale**:

- Operator explicit preference: keep Titan v2 for now.
- EOL is 10 weeks out; capacity planning is the right next-feature trigger, not a premature removal.

---

## Decision 10 — Pentest assertion update

**Decision**: Update `pentest/scripts/sidecar.sh` so the unauthenticated `/v1/videos/health` probe expects HTTP 401, not 200.

**Rationale**:

- The pentest suite is a security gate: it should assert the intended posture, not a historical accident.
- Catching this in CI after the deploy would produce a confusing red herring; updating the assertion in the same commit keeps the suite aligned.

---

## Out-of-scope additions (explicitly deferred)

- Twelve Labs Pegasus 1.2 / Marengo 3.0 — valid Bedrock additions; defer to a separate feature.
- Mistral Pixtral Large — vision-capable Mistral; defer.
- Amazon Nova 2 Pro — preview only, profile not yet confirmed in the official Bedrock inference-profiles-support page; defer.
- Nova Canvas / Nova Reel replacements — no announced successor; separate feature when replacements exist (the EOL is 2026-09-30, giving ~5 months to schedule).
- Prisma client upgrade (0.11.0 → 0.15.0) — no LiteLLM compatibility signal demanding it.
- PostgreSQL 15 → 16 — no driver; defer until AL2023 signals PG15 deprecation.
- GitHub Actions / CI scanner bumps — Dependabot covers them.

## Summary

All ten decisions are locked. `research.md` carries the `Decision → Rationale → Alternatives considered` triad required by the plan template. Ready for Phase 1.
