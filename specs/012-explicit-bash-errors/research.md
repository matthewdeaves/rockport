# Research: Explicit Bash Error Handling

**Date**: 2026-03-22

## Current State Audit

### Script Sizes
| Script | Lines | Complexity |
|--------|-------|-----------|
| bootstrap.sh | 345 | Medium — linear flow, many system commands |
| rockport.sh | 1769 | High — 20+ functions, AWS/jq pipelines |
| setup.sh | 221 | Low — mostly install-and-check patterns |
| smoke-test.sh | 331 | Medium — curl-heavy test harness |

### Commands Relying on `set -e` (No Explicit Error Handling)

| Script | Count | Most Critical |
|--------|-------|--------------|
| bootstrap.sh | ~70 | dd, mkswap, postgresql-setup, psql DDL, systemctl, prisma |
| rockport.sh | ~60 | aws iam (15+ calls), jq pipelines (30+), terraform commands |
| setup.sh | ~25 | Package installs, `curl \| sudo sh` (line 111) |
| smoke-test.sh | ~80 | All curl test calls (by design — test harness) |

### `|| true` Workarounds (Existing `set -e` Friction)

| Script | Count | Purpose |
|--------|-------|---------|
| bootstrap.sh | 0 | — |
| rockport.sh | 17 | grep returning empty, optional API calls, optional cleanup |
| setup.sh | 0 | — |
| smoke-test.sh | 1 | Cleanup trap |

### Pipelines Relying on `pipefail`

| Script | Count | Key Patterns |
|--------|-------|-------------|
| bootstrap.sh | 4 | psql\|grep (2x), sha256sum\|awk, tee |
| rockport.sh | 30+ | echo\|jq (many), echo\|awk (7), echo\|grep, printf\|sed\|grep |
| setup.sh | 6 | curl\|sudo sh, curl\|grep, aws\|head |
| smoke-test.sh | 0 | Uses here-strings (<<<), not pipes |

### `local var=$(cmd)` Masking Exit Codes

| Script | Count | Notes |
|--------|-------|-------|
| bootstrap.sh | 0 | Uses global scope; 1 unsafe pipeline assignment |
| rockport.sh | 20+ | Most aws/jq calls in functions use this pattern |
| setup.sh | 0 | No local+command patterns |
| smoke-test.sh | 0 | No local+command patterns |

### Variables Relying on `set -u`

| Script | Risk | Notes |
|--------|------|-------|
| bootstrap.sh | 7 vars | All Terraform-injected — need validation guard |
| rockport.sh | Low | Most already use `${var:-}` or `${var:?}` |
| setup.sh | None | All variables properly initialized |
| smoke-test.sh | None | Uses `${N:-default}` and `${N:?msg}` patterns |

## Design Decisions

### Decision 1: `die()` Function Signature

**Decision**: `die() { echo "ERROR: $*" >&2; exit 1; }`

**Rationale**: Simple, consistent with existing error messages in the codebase (many already use `echo "ERROR: ..." >&2; exit 1`). No need for stack traces or line numbers — these are ops scripts, not libraries.

**Alternatives considered**:
- `die() { printf ... }` — unnecessary complexity
- Shared library sourced by all scripts — adds a dependency; each script should be self-contained
- Different exit codes per error — not needed; callers only check zero/non-zero

### Decision 2: When NOT to Add Error Handling

**Decision**: Don't add `|| die` to commands that are:
1. Already inside an `if` condition (error is handled by the branch)
2. Intentionally allowed to fail (e.g., `grep` returning no match in a filter)
3. In cleanup/trap handlers (best-effort is correct)
4. Echo/printf to stdout/stderr (failure is not actionable)

**Rationale**: Over-checking creates noise. The goal is catching real failures, not making every line defensive.

### Decision 3: Pipeline Handling Strategy

**Decision**: For `echo "$data" | jq '...'` patterns, check the result after the pipeline rather than rewriting as `jq '...' <<< "$data"`.

**Rationale**:
- The `echo | jq` pattern is idiomatic and readable
- jq failures on bad input produce empty output, which is caught by subsequent `-z` checks
- Rewriting 30+ pipelines to here-strings would be churn with no safety benefit
- For critical pipelines (sha256sum, curl), split into separate commands

### Decision 4: smoke-test.sh Approach

**Decision**: Minimal changes. The test harness already has its own `check()` function that catches failures. Most curl calls are intentionally tested for specific HTTP codes.

**Rationale**: The smoke test's `check()` function (line 44) already handles pass/fail for each test case. The script's error handling is fundamentally different from the other scripts — it expects failures as part of testing.

### Decision 5: `|| true` Cleanup

**Decision**: Remove `|| true` where the explicit error handling makes it unnecessary. Keep `|| true` only in cleanup/trap handlers and genuinely optional operations.

**Rationale**: 17 instances in rockport.sh exist solely because `set -e` would otherwise kill the script. Without `set -e`, most become unnecessary noise. But some (like `grep` returning empty in a filter) are legitimate — grep returns 1 on no match, which isn't an error.

### Decision 6: bootstrap.sh Variable Validation

**Decision**: Add a validation block after the Terraform variable assignments (lines 10-16) that checks each is non-empty, replacing the role `set -u` played.

**Rationale**: These 7 variables are the only ones that relied on `set -u` for safety. A single validation block is cleaner than `${var:?msg}` on each one.
