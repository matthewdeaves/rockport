# Rockport Security Audit — Findings Report

**Date:** 2026-03-20
**Source:** GitHub Issues #7–#10 (security review, regulatory considerations, pentest guide, pentest considerations)
**Method:** Each finding fact-checked against the current codebase

---

## Issue #7 — Security Review (21 findings)

All 21 findings were verified as **factually accurate** against the codebase. Every code reference, line number, and attack scenario checked out.

| ID | Finding | Valid? | Severity (Reviewer) | Severity (Ours) | Action |
|---|---|---|---|---|---|
| **CRIT-1** | Bedrock invoked before concurrent job limit checked — ghost jobs incur cost with no tracking | Yes | Critical | **Critical** | **Fix required.** `video_api.py:631` calls `start_async_invoke()` before `db.insert_job_if_under_limit()` at line 647. Swap order: reserve DB slot first, call Bedrock second, release slot on failure. |
| **HIGH-1** | cloudflared downloaded without SHA256 checksum verification | Yes | High | **High** | **Fix.** `bootstrap.sh:262-275` only checks `--version` string. Add `.sha256sum` download + `sha256sum -c` verification. |
| **HIGH-2** | Deployer IAM can `CreatePolicyVersion` on `RockportDeployer*` — escalation within project boundary | Yes | High | **High (accepted risk)** | Accept as inherent to self-managing IAM deployers. Long-term: CloudTrail alerting on `iam:CreatePolicyVersion`. |
| **HIGH-3** | Bedrock IAM uses `foundation-model/*` wildcard across 12 regions | Yes | High | **High** | **Fix.** `main.tf:59-81` — replace with specific model-family patterns (`anthropic.claude-*`, `amazon.nova-*`, `stability.*`, etc.) per region. |
| **HIGH-4** | No request body size limit — 20-shot × 14MB images = 280MB vs 256MB MemoryMax | Yes | High | **Medium** | **Fix.** Add body size middleware (~40MB limit). Downgraded because exploitation requires valid CF Access + API key, and systemd auto-restarts. |
| **MED-1** | pip packages installed without hash verification | Yes | Medium | Medium | **Fix.** Generate hashed requirements lock file, use `--require-hashes`. |
| **MED-2** | Bedrock `ClientError` messages returned verbatim — leaks ARNs, account IDs, regions | Yes | Medium | Medium | **Fix.** Log full error server-side, return generic message to client. Affects `video_api.py:637`, `image_api.py:279,335,441`. |
| **MED-3** | Instance role has `ssm:PutParameter` on all 3 SSM paths — post-compromise persistence | Yes | Medium | Medium | **Fix.** Scope `PutParameter` to `/rockport/db-password` only (the only one the instance writes). `main.tf:105-125`. |
| **MED-4** | Cloudflare service token has no expiry or rotation mechanism | Yes | Medium | Medium | Document rotation procedure. Add `rockport.sh` subcommand or calendar reminder. |
| **MED-5** | No rate limiting at Cloudflare edge | Yes | Medium | Medium | Add CF rate limiting rule if on Pro+ plan. LiteLLM's 60 RPM (`litellm-config.yaml:222`) provides app-layer protection. |
| **MED-6** | Bootstrap log world-readable (default umask) | Yes | Medium | **Low** | **Fix (trivial).** Add `chmod 600 "$LOG_FILE"` before `exec` in `bootstrap.sh:5-6`. |
| **MED-7** | No CloudTrail, VPC Flow Logs, or centralized logging in IaC | Yes | Medium | Medium | Add CloudTrail as Terraform resource. Preventive controls are strong; detective controls are absent. |
| **MED-8** | Deploy artifact tarball not integrity-verified | Yes | Medium | Medium | **Fix.** Add checksum file to S3 alongside artifact, verify in `bootstrap.sh:188-196`. |
| **MED-9** | No AI content filtering / guardrails | Yes | Medium | **Informational** | By design — transparent proxy. Document as accepted design decision. |
| **LOW-1** | Nova Reel `seed` field has no range validation (unlike image API) | Yes | Low | Low | **Fix (trivial).** Add `Field(default=None, ge=0, le=2_147_483_646)` to `video_api.py:198`. |
| **LOW-2** | SSM command documents not scoped to specific documents | Yes | Low | Low | **Fix.** Scope to `AWS-RunShellScript` in `deployer-policies/iam-ssm.json:119-126`. |
| **LOW-3** | Video health endpoint unauthenticated + probes Bedrock on every call | Yes | Low | Low | Optional: add response caching on health probe. CF Access still protects at edge. |
| **LOW-4** | State bucket missing DenyNonSSL during initial creation | Yes | Low | Low | **Fix.** Add bucket policy in `rockport.sh` `ensure_state_backend` function. |
| **LOW-5** | Admin API paths exposed at network level | Yes | Low (accepted) | Low (accepted) | By design — required for CLI. Optional: IP allowlisting. |
| **LOW-6** | No CORS policy on sidecar | Yes | Low | **N/A** | Not exploitable — no browser clients. Only relevant if browser UI is ever added. |
| **LOW-7** | Missing security response headers on sidecar | Yes | Low | **N/A** | Same as LOW-6 — API-only service, no browser clients. |

---

## Issue #8 — Regulatory Considerations (17 items)

All factual claims verified. However, most items are **inapplicable for a personal single-user project**. The review itself acknowledges this in its applicability note.

| Item | Claim | Verified? | Relevant for Personal Project? | Action |
|---|---|---|---|---|
| Video prompts stored indefinitely | `rockport_video_jobs.prompt` has no TTL or cleanup | Yes | Low | Good practice: add retention policy (e.g., nullify prompt after 90 days) |
| Data subject rights (access/erasure) | No mechanism exists | Yes | **No** — operator IS the data subject with direct DB access | None |
| EU GDPR applicability | No documentation of lawful basis | Yes | **No** — single-user tool | None |
| EU AI Act Article 50 (content marking) | No C2PA/IPTC metadata on generated images/videos | Yes | **No** unless publishing content publicly (deadline Aug 2026) | None currently |
| International data transfers UK→US | Image/video prompts sent to us-east-1/us-west-2, not documented | Yes | Low — AWS DPA with SCCs covers this | Document reliance on AWS DPA |
| S3 encryption | SSE-S3 + DenyNonSSL on all buckets | Yes (correctly described as adequate) | N/A — already done | None |
| CloudTrail | Not implemented in IaC | Yes | Low-medium — useful for security | Same as MED-7 above |
| LiteLLM chat/text logging | No `success_callback` configured | Yes | Low | Optional: add `success_callback: ["postgres"]` for visibility |
| Privacy notice | Not provided | Yes | **No** | None |
| DPIA | Not completed | Yes | **No** | None |
| Article 30 processing records | Not maintained | Yes | **No** | None |
| Auth event logging | Errors to ephemeral journal only | Yes | Low | Addressed by MED-7 |
| S3 access logging | Explicitly disabled on all 3 buckets | Yes | Low — ephemeral 7-day video output | None |
| Centralized log shipping | Not implemented | Yes | Low-medium | Addressed by MED-7 |
| EU Representative | Not appointed | Yes | **No** | None |
| VPC Flow Logs | Not implemented | Yes | Low | Optional |
| Content filtering | Absent by design | Yes | **No** | None |

**Bottom line:** 3 items worth doing for operational hygiene (prompt retention, CloudTrail, optional LiteLLM logging). The rest are N/A for a personal project.

---

## Issue #9 — Pentest Guide (11 test areas)

Methodology document organized around STRIDE/MITRE ATLAS/OWASP LLM Top 10. All described attack surfaces verified against codebase.

| Test Area | Attack Surface Exists? | Key Finding |
|---|---|---|
| CF Access + service token | Yes | `access.tf:22` uses `any_valid_service_token = {}` — any token in the CF account works, not just the Rockport one |
| WAF path bypass | Yes (theoretical) | `starts_with()` matching could be vulnerable to path normalization tricks |
| CRIT-1 race condition | **Yes — still present** | Bedrock called before DB limit check; advisory lock only prevents DB race, not Bedrock race |
| DoS / OOM | Yes | 20-shot × 14MB + 2×35MB Ray2 images vs 256MB MemoryMax |
| Error message info leak | Yes | Raw Bedrock `ClientError` forwarded to clients |
| IAM scope / escalation | Yes (constrained) | `foundation-model/*` wildcard + `ssm:PutParameter` on all params |
| S3 presigned URLs | Yes (limited) | 1-hour expiry, UUID4 paths, key-scoped access |
| Cross-key DB isolation | Minimal | All queries parameterized and filtered by `api_key_hash` |
| Prompt injection | Conditional | Transparent proxy by design — tests would evaluate Bedrock, not Rockport |
| Supply chain | Yes | No hash pinning for pip or cloudflared |
| SSRF | **No** (sidecar) | Images are data URIs only, no URL fetching |

**New finding from pentest guide analysis:** Video endpoints do NOT enforce `claude-only` key restrictions (image API does at `image_api.py:93-100`, video API does not check).

---

## Issue #10 — Pentest Considerations (7 phases)

Pre-engagement planning document. All attack surfaces verified.

| Phase | Key Risks Identified | Accurate? | Notes |
|---|---|---|---|
| 1. Recon & fingerprinting | WAF bypass, health endpoint info leak, error message leak | Yes | `starts_with()` WAF + unauthenticated `/v1/videos/health` |
| 2. Auth & authz | Key isolation, claude-only enforcement, CF Access breadth | Yes | `any_valid_service_token` is overly broad; video lacks claude-only check |
| 3. Business logic | Budget race, CRIT-1, denial-of-wallet | Yes | Budget check is non-atomic; Bedrock fires before concurrent limit |
| 4. AI-specific | Prompt injection, model access beyond config, prompt storage | Yes | IAM `foundation-model/*` allows bypassing LiteLLM model list |
| 5. Infrastructure | Instance secrets, SSM PutParameter, S3 tampering | Yes | `/etc/litellm/env` contains master key + DB URL; no artifact checksums |
| 6. DoS | Memory exhaustion, health endpoint abuse, connection flood | Yes | 280MB payload vs 256MB MemoryMax; health probes Bedrock on every call |
| 7. CI/CD | Actions pinned to tags not SHAs, tfplan may contain secrets, OIDC scope | Yes | `id-token: write` at workflow level gives all jobs OIDC capability |

---

## Priority Recommendations

### Must fix (before next deploy)
1. **CRIT-1** — Swap Bedrock invoke and DB insert order in `video_api.py`
2. **HIGH-3** — Scope Bedrock IAM to specific model families in `main.tf`
3. **HIGH-4** — Add request body size limit middleware to sidecar

### Should fix (next iteration)
4. **HIGH-1** — Add SHA256 checksum verification for cloudflared in `bootstrap.sh`
5. **MED-2** — Sanitize Bedrock error messages before returning to clients
6. **MED-3** — Scope `ssm:PutParameter` to `/rockport/db-password` only
7. **MED-8** — Add checksum verification for deploy artifacts
8. **NEW** — Add `claude-only` key enforcement to video endpoints
9. **LOW-1** — Add seed range validation to `VideoGenerationRequest`

### Good hygiene (when convenient)
10. **MED-1** — Generate hashed pip requirements lock file
11. **MED-6** — `chmod 600` the bootstrap log
12. **MED-7** — Add CloudTrail to Terraform
13. **LOW-2** — Scope SSM documents to `AWS-RunShellScript`
14. **LOW-4** — Add DenyNonSSL to state bucket creation in `rockport.sh`

### Accept as-is
- **HIGH-2** — Deployer IAM escalation (inherent to self-managing deployers)
- **MED-4** — CF service token rotation (document procedure)
- **MED-5** — Edge rate limiting (LiteLLM app-layer RPM is adequate for now)
- **MED-9** — No content filtering (by design)
- **LOW-5** — Admin paths exposed (required for CLI)
- **LOW-6/7** — No CORS/security headers (no browser clients)

---

## Overall Assessment

**Review quality: Excellent.** Every single finding across all four issues was verified as factually accurate against the codebase. Code references, line numbers, and attack scenarios are precise. This is a thorough, professional-grade security review.

**One new finding emerged** that wasn't in the original review: video endpoints don't enforce `claude-only` key restrictions, unlike the image API.

**The single highest-priority item is CRIT-1** — the Bedrock-before-guard race condition that can create ghost jobs costing $0.48–$13.50 each with no tracking or cancellation ability.
