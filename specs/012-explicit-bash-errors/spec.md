# Feature Specification: Explicit Bash Error Handling

**Feature Branch**: `012-explicit-bash-errors`
**Created**: 2026-03-22
**Status**: Draft
**Input**: User description: "Remove set -euo pipefail from all bash scripts and replace with explicit error handling"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Predictable Script Failure Behavior (Priority: P1)

As a developer running any Rockport bash script, I want every
failure to produce a clear error message and exit cleanly, so
that I can diagnose problems without understanding bash's
implicit errexit rules.

**Why this priority**: This is the core value — scripts that
fail explicitly with useful messages instead of silently
continuing or exiting at unexpected points due to `set -e`
edge cases.

**Independent Test**: Run each script with a simulated failure
(e.g., missing dependency, bad AWS credentials, unreachable
endpoint) and verify the script exits with a descriptive
error message and non-zero exit code.

**Acceptance Scenarios**:

1. **Given** a script encounters a failing command, **When** the
   command returns non-zero, **Then** the script prints a
   descriptive error message to stderr and exits with a non-zero
   code.
2. **Given** a script uses a pipeline, **When** a command in the
   pipeline fails, **Then** the failure is caught explicitly and
   reported, not silently swallowed.
3. **Given** a script references an optional variable that is
   unset, **When** the script runs, **Then** it uses a default
   value instead of crashing with "unbound variable".

---

### User Story 2 - Consistent Error Handling Pattern (Priority: P2)

As a developer maintaining Rockport scripts, I want a single
consistent `die()` helper pattern across all scripts, so that
error handling is uniform and easy to follow.

**Why this priority**: Consistency reduces cognitive load when
reading or modifying scripts. A shared pattern makes it obvious
how to handle new error cases.

**Independent Test**: Grep all bash scripts for error handling
patterns and verify they all use the same `die()` function
signature and `|| die` / `if ! cmd; then die` patterns.

**Acceptance Scenarios**:

1. **Given** any Rockport bash script, **When** I search for the
   error handling pattern, **Then** I find a `die()` function
   defined near the top.
2. **Given** a command that can fail, **When** I read the code
   around it, **Then** I see explicit error handling using
   `|| die`, `if ! cmd; then die`, or `$?` checks — never
   implicit errexit.

---

### User Story 3 - No Implicit Bash Safety Flags (Priority: P3)

As a developer, I want zero instances of `set -e`, `set -u`,
`set -o pipefail`, or `set -euo pipefail` in any Rockport bash
script, so that the codebase fully commits to explicit error
handling.

**Why this priority**: Removing the flags without adding
explicit checks would be dangerous. This story is about the
cleanup itself, which depends on the explicit checks (US1)
being in place first.

**Independent Test**: Grep all `.sh` files for `set -e`,
`set -u`, `set -o pipefail`, and `set -euo pipefail` — expect
zero matches.

**Acceptance Scenarios**:

1. **Given** the Rockport codebase, **When** I search all `.sh`
   files for `set -e`, `set -u`, `set -o pipefail`, or
   `set -euo pipefail`, **Then** zero matches are found.

---

### Edge Cases

- What happens when `local var=$(cmd)` is used — does the
  explicit pattern still catch the failure? (Yes — the explicit
  pattern avoids `local` masking by separating declaration and
  assignment, or by checking after assignment.)
- What happens in subshells (`$(...)`) — do errors propagate?
  (Explicit checks after the subshell capture the exit code.)
- What about `trap` handlers — do they still work correctly
  without `set -e`? (Yes — traps are independent of errexit.)
- What about CI (GitHub Actions) — does the workflow still
  detect script failures? (Yes — the scripts themselves call
  `exit 1` on failure, which CI detects.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: All bash scripts MUST NOT contain `set -e`,
  `set -u`, `set -o pipefail`, or any combination thereof.
- **FR-002**: Each bash script MUST define a `die()` helper
  function that prints an error message to stderr and exits
  with a non-zero code.
- **FR-003**: Every command that can fail MUST have explicit
  error handling using one of: `|| die "message"`,
  `if ! cmd; then die "message"; fi`, or `$?` inspection.
- **FR-004**: Optional/unset variables MUST use default-value
  syntax (`${VAR:-default}`) instead of relying on `set -u`.
- **FR-005**: Pipeline errors MUST be handled explicitly by
  checking the result of the pipeline or the specific command
  that matters.
- **FR-006**: Existing script behavior (success paths) MUST
  remain unchanged — this is a refactor, not a feature change.
- **FR-007**: All scripts MUST continue to exit with
  appropriate non-zero codes on failure so that CI and
  callers can detect errors.

### Key Entities

- **bootstrap.sh** (345 lines): EC2 user_data script — runs
  as root during first boot. Installs PostgreSQL, LiteLLM,
  cloudflared, video sidecar. Failures here leave
  infrastructure half-configured.
- **rockport.sh** (1769 lines): Admin CLI — the largest
  script. Many subcommands, helper functions, AWS CLI calls.
  Most complex error handling needs.
- **setup.sh** (221 lines): Dev tool installer — runs on
  developer machines. Installs AWS CLI, Terraform, jq, etc.
- **smoke-test.sh** (331 lines): Post-deploy verification —
  runs after deploy. Tests routing, auth, validation.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero instances of `set -e`, `set -u`,
  `set -o pipefail` across all `.sh` files in the repository.
- **SC-002**: Every script that currently works continues to
  work identically on success paths (no behavioral regression).
- **SC-003**: Every script produces a descriptive error message
  on stderr when encountering a failure, rather than silently
  exiting or continuing.
- **SC-004**: All four scripts pass shellcheck with no new
  warnings introduced.
- **SC-005**: CI pipeline (GitHub Actions) continues to detect
  script failures correctly.
