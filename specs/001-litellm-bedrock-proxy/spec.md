# Feature Specification: LiteLLM Bedrock Proxy

**Feature Branch**: `001-litellm-bedrock-proxy`
**Created**: 2026-03-13
**Status**: Draft
**Input**: User description: "Rockport: A secure, cheap LiteLLM proxy service on AWS that lets users point Claude Code at Amazon Bedrock models through a single endpoint."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Use Claude Code with Bedrock Models (Priority: P1)

A developer configures their Claude Code settings file to point
at the Rockport endpoint (e.g., `llm.matthewdeaves.com`) with
their virtual API key. They open Claude Code and start a coding
session. Claude Code connects to Rockport, authenticates with the
virtual key, and sends requests to Bedrock. The developer can use
`/model` to switch between available models (e.g., Claude Sonnet,
Claude Opus, Llama) mid-session. Streaming responses appear in
real time, identical to using the native Anthropic API.

**Why this priority**: This is the core use case — without this
working end-to-end, the project has no value.

**Independent Test**: Configure Claude Code to point at Rockport,
send a chat completion request, and verify a streamed response
is returned from a Bedrock model.

**Acceptance Scenarios**:

1. **Given** a deployed Rockport instance with Bedrock models
   configured, **When** a user configures Claude Code with the
   Rockport endpoint URL and their virtual key, **Then** Claude
   Code connects and operates normally with streamed responses.
2. **Given** an active Claude Code session, **When** the user
   runs `/model` to list available models, **Then** all
   configured Bedrock models appear with clean friendly names.
3. **Given** an active Claude Code session, **When** the user
   switches to a different model via `/model`, **Then**
   subsequent requests use the newly selected model.
4. **Given** an invalid or revoked virtual key, **When** a user
   attempts to connect, **Then** the request is rejected with
   a clear authentication error before any Bedrock call is made.

---

### User Story 2 - Use Claude Code with Non-Anthropic Bedrock Models (Priority: P1)

A developer uses Claude Code through Rockport but switches to a
non-Anthropic model (e.g., Meta Llama, Amazon Nova, Mistral) via
`/model`. This lets them use cheaper models for simpler tasks and
reserve expensive models for complex work, reducing overall
Bedrock token costs.

**Why this priority**: Multi-model access is a key value
proposition — using cheaper Bedrock models for routine tasks
significantly reduces costs.

**Independent Test**: Configure Claude Code to point at Rockport,
switch to a Llama or Nova model via `/model`, and verify the
response comes from that model.

**Acceptance Scenarios**:

1. **Given** a deployed Rockport instance with Llama and Nova
   models configured, **When** a user switches to `nova-pro`
   via `/model`, **Then** subsequent responses come from the
   Amazon Nova Pro model on Bedrock.
2. **Given** a user on a non-Anthropic model, **When** they
   switch back to a Claude model, **Then** responses come from
   Claude on Bedrock with no issues.

---

### User Story 3 - Admin Deploys the Service (Priority: P2)

The admin runs a single IaC command to deploy the entire Rockport
stack from scratch: EC2 instance, networking, IAM roles,
Cloudflare Tunnel, PostgreSQL, and LiteLLM. After deployment, the
admin generates a virtual key for themselves and verifies the
service is working. The whole process from `git clone` to a
working service takes under 30 minutes.

**Why this priority**: Without deployment, nothing else works.
Ranked P2 because it's an operator concern, not end-user value,
but it's a prerequisite for P1.

**Independent Test**: Run the IaC deploy command on a fresh AWS
account with Bedrock access enabled, then curl the health
endpoint through the Cloudflare subdomain.

**Acceptance Scenarios**:

1. **Given** an AWS account with Bedrock access and a Cloudflare
   account with `matthewdeaves.com`, **When** the admin runs the
   single deploy command, **Then** the full stack is provisioned
   and the service is reachable at the configured subdomain.
2. **Given** a deployed Rockport instance, **When** the admin
   runs a curl command to `/key/generate` with the master key,
   **Then** a new virtual API key is returned.
3. **Given** a deployed Rockport instance, **When** the admin
   runs the single teardown command, **Then** all AWS resources
   are destroyed cleanly.

---

### User Story 4 - Admin Manages Service via CLI (Priority: P2)

The admin manages all day-to-day operations using a `rockport`
bash CLI script that wraps LiteLLM's built-in admin API and AWS
CLI. The script fetches the master key from SSM automatically,
calls the right LiteLLM endpoints, and formats the output. No
need to remember curl syntax or endpoint URLs.

**Why this priority**: Elevated to P2 because this is the primary
admin interface. Without it, every operation requires remembering
curl syntax, fetching the master key manually, and parsing raw
JSON. The script makes admin tasks trivial.

**Independent Test**: Run `rockport status` and verify it returns
health info. Run `rockport key create test` and verify a key is
returned. Run `rockport key revoke <key>` and verify it's revoked.

**Acceptance Scenarios**:

1. **Given** a deployed Rockport instance, **When** the admin
   runs `rockport status`, **Then** the service health, running
   models, and instance info are displayed.
2. **Given** a deployed Rockport instance, **When** the admin
   runs `rockport key create alice`, **Then** a new virtual key
   is generated and displayed (master key fetched from SSM
   automatically).
3. **Given** an existing virtual key, **When** the admin runs
   `rockport key revoke sk-xxx`, **Then** the key is revoked
   and subsequent requests with it are rejected.
4. **Given** a deployed Rockport instance, **When** the admin
   runs `rockport key list`, **Then** all active keys are
   listed with their names and spend.
5. **Given** a deployed Rockport instance, **When** the admin
   runs `rockport logs`, **Then** recent LiteLLM logs are
   displayed without needing an interactive SSM session.
6. **Given** a deployed Rockport instance, **When** the admin
   runs `rockport models`, **Then** all configured Bedrock
   models are listed with their aliases.
7. **Given** the rockport CLI, **When** the admin runs
   `rockport deploy`, **Then** `terraform apply` is executed.
8. **Given** the rockport CLI, **When** the admin runs
   `rockport destroy`, **Then** confirmation is required before
   `terraform destroy` is executed.

---

### User Story 5 - Admin Upgrades the Service (Priority: P3)

The admin updates LiteLLM version, changes Bedrock model
configuration, or modifies infrastructure by pushing changes to
git and running the deploy command. The upgrade completes with
minimal downtime (seconds). Existing virtual keys and user data
survive the upgrade.

**Why this priority**: Ongoing maintenance is needed but not for
initial launch.

**Independent Test**: Change a model alias in config, redeploy,
verify the new model appears in `/v1/models` and existing keys
still work.

**Acceptance Scenarios**:

1. **Given** a running Rockport instance, **When** the admin
   adds a new Bedrock model to config and redeploys, **Then**
   the new model appears in `/v1/models` and existing keys
   still work.
2. **Given** a running Rockport instance, **When** the admin
   upgrades the LiteLLM version and redeploys, **Then** the
   service resumes with all existing keys and data intact.
3. **Given** a running Rockport instance, **When** the deploy
   command runs, **Then** downtime is limited to seconds (a
   service restart), not minutes.

---

### Edge Cases

- What happens when a Bedrock model is not enabled in the AWS
  account? LiteLLM returns the Bedrock error to the client.
- What happens when the Cloudflare Tunnel disconnects?
  `cloudflared` systemd service auto-restarts and reconnects.
- What happens when PostgreSQL crashes? Systemd auto-restarts
  it. LiteLLM reconnects automatically.
- What happens when a user sends a request with an expired or
  invalid key? LiteLLM rejects it before calling Bedrock.
- What happens when the EC2 instance runs out of memory?
  Systemd restart policies recover the services. EBS snapshots
  protect data.
- What happens during a model switch if the selected model is
  not available in Bedrock? LiteLLM returns an error and the
  user can switch to another model.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose an Anthropic-compatible
  `/v1/messages` endpoint that accepts requests from Claude
  Code without modification to that tool.
- **FR-002**: System MUST support SSE streaming responses so
  tokens appear in real time in Claude Code.
- **FR-003**: System MUST expose available Bedrock models with
  clean, client-friendly alias names so users can switch
  models via `/model` in Claude Code.
- **FR-004**: System MUST authenticate every request using
  LiteLLM's virtual key system before forwarding to Bedrock.
- **FR-005**: System MUST provide a `rockport` bash CLI script
  that wraps LiteLLM's admin API and AWS CLI for all day-to-day
  admin operations (key management, status, logs, deploy). The
  script MUST fetch the master key from SSM automatically.
- **FR-006**: System MUST route requests to Amazon Bedrock
  models based on the `model` field in the request, as
  defined in the LiteLLM configuration.
- **FR-007**: System MUST be deployable from a fresh AWS
  account to a working service with a single IaC command
  (after prerequisites: Bedrock model access grants,
  Cloudflare account setup, SSM secrets stored).
- **FR-008**: System MUST be upgradeable (LiteLLM version,
  config changes, infrastructure changes) with a single
  command and minimal downtime (seconds).
- **FR-009**: System MUST recover automatically from service
  crashes (LiteLLM, PostgreSQL, cloudflared) via systemd
  auto-restart.
- **FR-010**: System MUST recover automatically from underlying
  hardware failure via EC2 auto-recovery.
- **FR-011**: System MUST store all virtual keys and user data
  in PostgreSQL, with data protected by automated daily EBS
  snapshots.
- **FR-012**: System MUST be accessible only via Cloudflare
  Tunnel with no public IP and no inbound security group
  rules on the EC2 instance.
- **FR-013**: Infrastructure cost (excluding Bedrock token
  charges) MUST stay under £15/month.

### Key Entities

- **User**: A person who connects Claude Code to Rockport. Identified by a virtual API key. Has access to all
  configured models.
- **Virtual Key**: An API key generated by LiteLLM, stored in
  PostgreSQL. Used to authenticate requests. Can be created and
  revoked by the admin.
- **Admin**: The single operator who deploys, configures, and
  manages the service. Authenticated with the master key.
- **Model**: A Bedrock model exposed through LiteLLM with a
  client-friendly alias name. Defined in configuration.

### Assumptions

- The admin already has an AWS account with Bedrock model access
  enabled in `eu-west-2`.
- The admin already has a Cloudflare account managing
  `matthewdeaves.com`.
- The admin is comfortable with CLI tools, IaC, and AWS concepts.
- Claude Code both support configuring a custom
  OpenAI-compatible endpoint via their settings files.
- The user count is small (under 10 active users).
- There are no compliance, PII, or data-retention requirements.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can configure Claude Code and start a
  coding session through Rockport in under 5 minutes (given
  they have their key and the endpoint URL).
- **SC-002**: A user can switch to a cheaper Bedrock model
  (e.g., Nova Lite) for routine tasks and back to Claude for
  complex tasks within the same Claude Code session.
- **SC-003**: Streaming responses appear in CLI tools with no
  perceptible delay compared to native API access (proxy adds
  less than 100ms overhead).
- **SC-004**: An admin can deploy the entire stack from scratch
  in under 30 minutes (including IaC command execution time).
- **SC-005**: An admin can generate a new virtual key in under
  1 minute using a single curl command.
- **SC-006**: Service uptime is 99.9%+ (excluding AWS/Cloudflare
  regional outages), with automatic recovery from crashes
  within 30 seconds.
- **SC-007**: Monthly infrastructure cost (excluding Bedrock
  token charges) stays under £15.
- **SC-008**: Model switching via `/model` in CLI tools works
  seamlessly — the user sees the new model's responses on
  their next request.
