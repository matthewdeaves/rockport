# Implementation Plan: Explicit Bash Error Handling

**Branch**: `012-explicit-bash-errors` | **Date**: 2026-03-22 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/012-explicit-bash-errors/spec.md`

## Summary

Remove `set -euo pipefail` from all 4 bash scripts (bootstrap.sh, rockport.sh, setup.sh, smoke-test.sh) and replace with explicit error handling. Add a `die()` helper to each script, add explicit `|| die` / `if ! cmd` checks after commands that can fail, remove unnecessary `|| true` workarounds, and validate Terraform-injected variables in bootstrap.sh.

## Technical Context

**Language/Version**: Bash (no minimum version requirement — AL2023 ships bash 5.2)
**Primary Dependencies**: None (pure bash refactor)
**Storage**: N/A
**Testing**: shellcheck (lint), manual verification, CI smoke tests
**Target Platform**: Amazon Linux 2023 (bootstrap.sh), Ubuntu/macOS (setup.sh, rockport.sh), CI runners (smoke-test.sh)
**Project Type**: CLI / ops scripts
**Performance Goals**: N/A (no runtime performance impact)
**Constraints**: Zero behavioral change on success paths; scripts must remain self-contained (no shared libraries)
**Scale/Scope**: 4 files, ~2,666 lines total

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Cost Minimization | PASS | No infrastructure changes |
| II. Security | PASS | No security surface changes |
| III. LiteLLM-First | PASS | Not adding custom application code |
| IV. Scope Containment | PASS | Refactor of existing scripts only |
| V. AWS London + Cloudflare | PASS | No region/provider changes |
| VI. Explicit Bash Error Handling | PASS | This IS the implementation of Principle VI |

## Project Structure

### Documentation (this feature)

```text
specs/012-explicit-bash-errors/
├── plan.md              # This file
├── research.md          # Audit of current error handling patterns
├── spec.md              # Feature specification
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Implementation tasks (speckit.tasks output)
```

### Source Code (files modified)

```text
scripts/
├── bootstrap.sh         # 345 lines — EC2 user_data
├── rockport.sh          # 1769 lines — Admin CLI
└── setup.sh             # 221 lines — Dev tool installer

tests/
└── smoke-test.sh        # 331 lines — Post-deploy verification
```

**Structure Decision**: No new files. All changes are in-place edits to existing scripts.

## Implementation Approach

### Pattern: die() Helper

Each script gets this at the top, after the shebang:

```bash
die() { echo "ERROR: $*" >&2; exit 1; }
```

### Pattern: Explicit Error Checks

Three patterns, chosen by context:

```bash
# One-liner for simple commands
some_command || die "some_command failed"

# Multi-line for commands needing cleanup or context
if ! some_command; then
    echo "ERROR: some_command failed" >&2
    exit 1
fi

# When exit code matters
some_command
rc=$?
if [ "$rc" -ne 0 ]; then
    die "some_command failed with code $rc"
fi
```

### Pattern: Variable Validation (bootstrap.sh only)

```bash
# Validate Terraform-injected variables
for var in REGION MASTER_KEY_SSM_PATH TUNNEL_TOKEN_SSM_PATH \
           LITELLM_VERSION CLOUDFLARED_VERSION CLOUDFLARED_SHA256 \
           ARTIFACTS_BUCKET; do
    [ -n "${!var}" ] || die "Required variable $var is empty"
done
```

### What NOT to Change

- Commands inside `if` conditions (already explicitly handled)
- `echo`/`printf` to stdout/stderr (not actionable failures)
- Cleanup/trap handlers (best-effort is correct, keep `|| true`)
- grep in filter contexts where no-match is expected (not an error)
- smoke-test.sh `check()` function internals (test harness handles its own pass/fail)

### `|| true` Cleanup

The 17 `|| true` instances in rockport.sh fall into categories:
- **Remove**: Those that exist solely to prevent `set -e` from killing the script on non-error conditions (e.g., grep returning empty in a data extraction)
- **Keep**: Those in cleanup traps, genuinely optional operations (e.g., stopping a service that might not exist), and `2>/dev/null || true` on AWS calls that may legitimately fail

### Script-by-Script Scope

| Script | die() | Commands to check | || true to clean | Var validation | Pipelines |
|--------|-------|-------------------|------------------|----------------|-----------|
| bootstrap.sh | Add | ~70 | 0 | Add (7 vars) | 4 to fix |
| rockport.sh | Add | ~60 | 17 to review | None needed | ~30 (most are echo\|jq, low risk) |
| setup.sh | Add | ~25 | 0 | None needed | 6 to fix |
| smoke-test.sh | Add | Minimal | 1 (keep) | None needed | 0 |

## Complexity Tracking

No constitution violations to justify.
