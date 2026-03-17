# Feature Specification: Security Hardening

**Feature Branch**: `007-security-hardening`
**Created**: 2026-03-17
**Status**: Draft
**Input**: Six validated security issues requiring fixes across edge authentication, IAM policy, database auth, systemd sandboxing, idle monitoring, and concurrency control.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Restrict IAM Deployer Privileges (Priority: P1)

As a project owner, I want the deployer role to be unable to escalate its own privileges so that a compromised CI/CD pipeline cannot gain full AWS admin access through the instance role.

**Why this priority**: This is the highest-severity issue. A compromised deployer can currently attach AdministratorAccess to rockport roles, gaining unrestricted AWS access. This is an active privilege escalation path.

**Independent Test**: Verify that the deployer role cannot attach any AWS-managed policy (e.g., AdministratorAccess) to any rockport role. Only Terraform-managed, rockport-prefixed policies should be attachable.

**Acceptance Scenarios**:

1. **Given** a deployer with current IAM permissions, **When** they attempt to attach AdministratorAccess to the instance role, **Then** the request is denied by IAM.
2. **Given** a Terraform apply that attaches a rockport-prefixed custom policy, **When** the deploy runs, **Then** the policy attachment succeeds normally.
3. **Given** a deployer attempting to attach any AWS-managed policy (e.g., ReadOnlyAccess, PowerUserAccess), **When** the API call is made, **Then** the request is denied.

---

### User Story 2 - Add Edge Authentication via Cloudflare Access (Priority: P2)

As a project owner, I want requests to be authenticated at the Cloudflare edge before they reach the tunnel so that the proxy is not exposed to unauthenticated internet traffic.

**Why this priority**: Currently anyone who discovers the tunnel URL can hit allowed API paths. Adding edge authentication creates a second layer of defense beyond API keys.

**Independent Test**: Attempt to reach the proxy URL without valid Cloudflare Access credentials and confirm the request is blocked before reaching the tunnel.

**Acceptance Scenarios**:

1. **Given** a request without a valid service token, **When** it hits any allowed API path, **Then** Cloudflare returns a 403 before the request reaches the tunnel.
2. **Given** a request with a valid service token and valid API key, **When** it hits an allowed path, **Then** the request passes through to LiteLLM normally.
3. **Given** the existing admin CLI and Claude Code clients, **When** they are configured with the service token headers, **Then** all existing functionality continues to work.

---

### User Story 3 - Harden Systemd Service Sandboxing (Priority: P3)

As a project owner, I want the proxy and sidecar services to run with minimal system access so that a compromised service process cannot interact with devices, namespaces, or capabilities beyond what it needs.

**Why this priority**: The current hardening covers basics but leaves six additional sandboxing directives unset. Adding them reduces the blast radius of any service compromise.

**Independent Test**: After adding the directives, verify all three services (LiteLLM, cloudflared, video sidecar) start, run, and serve requests normally. Confirm via systemd-analyze security that the security score improves.

**Acceptance Scenarios**:

1. **Given** the updated service files, **When** each service starts, **Then** it runs without errors and serves requests.
2. **Given** a running service, **When** the process attempts to access /dev/ entries or create new namespaces, **Then** the kernel denies the operation.
3. **Given** the updated service files, **When** a security analysis is run against each service, **Then** the overall exposure score is lower than before.

---

### User Story 4 - Switch Database Authentication to SCRAM-SHA-256 (Priority: P4)

As a project owner, I want the database to use modern password hashing so that md5-based authentication is removed from audit findings.

**Why this priority**: Low practical risk (localhost-only traffic) but a simple one-line fix that eliminates a known-weak authentication method from the stack.

**Independent Test**: After redeployment, confirm the database accepts connections using scram-sha-256 and rejects md5 auth attempts.

**Acceptance Scenarios**:

1. **Given** a fresh instance bootstrapped with the updated script, **When** LiteLLM connects to the database, **Then** the connection uses scram-sha-256 authentication.
2. **Given** the updated authentication configuration, **When** a client attempts md5 authentication, **Then** the connection is rejected.

---

### User Story 5 - Improve Idle-Stop Monitoring (Priority: P5)

As a project owner, I want to be notified if the idle-stop check fails and I want CPU utilisation considered alongside network traffic so that the idle check is more robust and failures are visible.

**Why this priority**: If the idle check fails silently, the instance runs indefinitely, accumulating cost. Adding CPU as a signal also prevents false idle detection during compute-heavy but low-network workloads.

**Independent Test**: Simulate a check failure and confirm an alarm fires. Run a CPU-intensive workload with low network traffic and confirm the instance is not stopped.

**Acceptance Scenarios**:

1. **Given** the idle-stop check invocation fails, **When** the error metric increments, **Then** an alarm transitions to ALARM state.
2. **Given** an instance with high CPU but low network traffic, **When** the idle check runs, **Then** the instance is not stopped.
3. **Given** an instance with low CPU and low network traffic, **When** the idle check runs, **Then** the instance is stopped as before.

---

### User Story 6 - Fix Video Job Concurrency Race Condition (Priority: P6)

As a user submitting video jobs, I want the per-key concurrent job limit to be enforced atomically so that simultaneous requests cannot exceed the configured limit.

**Why this priority**: Low practical risk at current scale but a correctness issue. Two simultaneous requests can both pass the limit check and create jobs beyond the allowed maximum.

**Independent Test**: Submit multiple video generation requests simultaneously from the same API key and confirm the total in-progress jobs never exceeds the configured limit.

**Acceptance Scenarios**:

1. **Given** a key at its concurrent job limit, **When** two requests arrive simultaneously, **Then** at most one is accepted and the other is rejected.
2. **Given** the atomic enforcement, **When** a job completes and frees a slot, **Then** the next request is accepted normally.

---

### Edge Cases

- What happens if the Cloudflare Access service token expires or is rotated? Clients must be updated with the new token or requests will be blocked.
- What happens if a syscall filter blocks a syscall that a service actually needs? The service will fail to start or crash. The chosen filter set is broad but edge cases in Python/Go runtimes may require additions.
- What happens if the idle-stop error alarm fires due to a transient error? The alarm should require multiple consecutive failures before alerting (evaluation period) to avoid false positives.
- What happens if two video requests arrive in the same millisecond from different keys? The locking mechanism should be per-key, so different keys do not block each other.
- What happens if the deployer needs to attach a new custom policy during a Terraform apply? The restriction must allow rockport-prefixed custom policies while blocking AWS-managed policies.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST restrict the deployer role so that only rockport-prefixed custom policies can be attached to rockport roles.
- **FR-002**: System MUST deny the deployer from attaching any AWS-managed policy to any rockport role.
- **FR-003**: System MUST authenticate all incoming requests at the Cloudflare edge using a service token before traffic reaches the tunnel.
- **FR-004**: System MUST allow authenticated requests with valid service tokens to pass through to the proxy without modification.
- **FR-005**: System MUST apply syscall filtering, device isolation, namespace restriction, capability dropping, control group protection, and SUID/SGID restriction to all three services.
- **FR-006**: System MUST use scram-sha-256 for all database client authentication instead of md5.
- **FR-007**: System MUST monitor the idle-stop check for invocation errors and raise an alarm when errors occur.
- **FR-008**: System MUST consider CPU utilisation alongside network traffic when determining instance idleness.
- **FR-009**: System MUST enforce the per-key concurrent video job limit atomically so that simultaneous requests cannot exceed it.
- **FR-010**: System MUST continue to function correctly for all existing workflows (API requests, video generation, admin CLI) after all hardening changes are applied.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The deployer role cannot attach any AWS-managed policy to rockport roles, verified by policy simulation or attempted API call returning Access Denied.
- **SC-002**: Unauthenticated requests to the proxy URL receive a 403 response before reaching the tunnel.
- **SC-003**: All three services pass a security analysis with a reduced exposure score compared to baseline.
- **SC-004**: Database authentication uses scram-sha-256 exclusively; md5 does not appear in the authentication configuration.
- **SC-005**: An idle-stop check failure triggers an alarm within the configured evaluation period.
- **SC-006**: An instance with CPU utilisation above the idle threshold is not stopped regardless of network traffic level.
- **SC-007**: Under concurrent load, the number of in-progress video jobs per key never exceeds the configured limit.
- **SC-008**: All existing smoke tests pass after all changes are applied.

## Assumptions

- The Cloudflare plan supports Access service tokens (available on all paid plans and the free plan with Zero Trust).
- The chosen syscall filter set is compatible with Python 3.11 (uvicorn, FastAPI), Go (cloudflared), and PostgreSQL client libraries. If a needed syscall is blocked, the set can be extended with explicit additions.
- CPU utilisation metrics are available with sufficient granularity (5-minute period is acceptable for idle detection).
- The advisory lock approach for video job concurrency is compatible with the existing database connection pattern.
- Existing clients (Claude Code, admin CLI) can be configured to send Cloudflare Access service token headers alongside their existing API key headers.
