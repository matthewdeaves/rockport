# Feature Specification: Video Generation Sidecar API

**Feature Branch**: `004-video-generation-sidecar`
**Created**: 2026-03-16
**Status**: Draft
**Input**: User description: "Add video generation to Rockport via a Python sidecar API service running alongside LiteLLM on the same EC2 instance."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generate a Video from a Text Prompt (Priority: P1)

A user sends a text prompt describing a video they want to create. The system accepts the request, starts generating the video in the background, and returns a job identifier. The user polls for status and, once complete, receives a download link to the generated video. The cost of generation is tracked against their API key's budget.

**Why this priority**: This is the core value proposition — text-to-video generation is the primary use case and must work end-to-end before anything else matters.

**Independent Test**: Can be fully tested by submitting a POST request with a text prompt, polling the returned job ID until completion, and downloading the resulting video file. Delivers immediate value as a standalone capability.

**Acceptance Scenarios**:

1. **Given** a user with a valid API key and sufficient budget, **When** they submit a video generation request with a text prompt and duration, **Then** the system returns a job ID and an "in_progress" status immediately.
2. **Given** a video generation job is in progress, **When** the user polls the job status endpoint, **Then** they receive the current status ("in_progress", "completed", or "failed").
3. **Given** a video generation job has completed, **When** the user polls the job status, **Then** they receive a time-limited download URL for the video file.
4. **Given** a video generation job has completed, **When** the system records the cost, **Then** the spend appears in the unified spend reports alongside text and image generation costs.

---

### User Story 2 - Budget Enforcement for Video Generation (Priority: P2)

A user with a budget-limited API key attempts to generate a video. The system checks whether the estimated cost (based on requested duration) would exceed their remaining budget before starting the job. If it would, the request is rejected with a clear explanation of remaining budget and estimated cost.

**Why this priority**: Video generation is expensive ($0.08/second, so a 2-minute video costs $9.60). Without pre-flight budget checks, users could unknowingly exceed their budgets, creating billing disputes and unexpected costs.

**Independent Test**: Can be tested by creating a key with a small budget, spending most of it, then attempting a video generation that would exceed the remainder. Verify the request is rejected with an informative error.

**Acceptance Scenarios**:

1. **Given** a user's remaining budget is $1.00, **When** they request a 30-second video (estimated cost $2.40), **Then** the request is rejected with an error indicating insufficient budget.
2. **Given** a user's remaining budget is $5.00, **When** they request a 6-second video (estimated cost $0.48), **Then** the request is accepted and proceeds normally.
3. **Given** a user's API key has no budget limit, **When** they request any video generation, **Then** the budget check passes and the request proceeds.

---

### User Story 3 - Poll and List Video Generation Jobs (Priority: P2)

A user wants to check the status of a specific video job, or see all their recent video generation jobs. They can poll individual jobs by ID or list all jobs associated with their API key.

**Why this priority**: Essential for usability — video generation is async and can take minutes, so users need reliable status checking and job history.

**Independent Test**: Can be tested by creating several video jobs, then verifying that individual status checks and list queries return accurate, up-to-date information scoped to the requesting key.

**Acceptance Scenarios**:

1. **Given** a user has submitted multiple video jobs, **When** they list their jobs, **Then** they see only jobs associated with their own API key, ordered by most recent first.
2. **Given** a user has a job ID, **When** they poll for status, **Then** they receive the job's current status, and if completed, a download URL.
3. **Given** a user tries to access a job belonging to a different API key, **When** they poll that job ID, **Then** they receive a 404 (not found) response.

---

### User Story 4 - Admin Monitors Video Spend (Priority: P3)

An administrator uses the existing Rockport CLI to view spend reports. Video generation costs appear alongside text and image generation costs in the same reports, broken down by key.

**Why this priority**: Unified spend visibility is important for cost management but is a read-only reporting concern — the system works without it, just with less visibility.

**Independent Test**: Can be tested by generating a video, then running the spend summary and per-key spend breakdown commands to verify video costs appear in the output.

**Acceptance Scenarios**:

1. **Given** video generation jobs have been completed, **When** the admin runs the spend summary command, **Then** video costs are included in the total spend figures.
2. **Given** video generation jobs have been completed by different keys, **When** the admin runs the per-key spend breakdown, **Then** each key's video spend is reflected in their individual totals.

---

### User Story 5 - Multi-Shot Video Generation (Priority: P2)

A user wants fine-grained control over a longer video by providing separate prompts for each 6-second segment (shot). Instead of a single prompt for the entire video, they supply an array of shots, each with its own text prompt and optional keyframe image. The system stitches these into a cohesive multi-shot video. This enables narrative storytelling, scene transitions, and precise creative control.

**Why this priority**: Multi-shot is the differentiating capability of the video generation service. Without it, users are limited to single-prompt videos where they have no control over pacing or scene changes. This is essential for any serious creative use.

**Independent Test**: Can be tested by submitting a request with an array of 2-3 shot prompts, each describing a different scene, and verifying the resulting video contains distinct segments matching the prompts in sequence.

**Acceptance Scenarios**:

1. **Given** a user provides an array of 2 or more shot prompts, **When** they submit a multi-shot video generation request, **Then** the system accepts the request, calculates total duration as 6 seconds per shot, and returns a job ID.
2. **Given** a user provides 20 shots (the maximum), **When** they submit the request, **Then** the system accepts it and generates a 120-second video.
3. **Given** a user provides more than 20 shots, **When** they submit the request, **Then** the system rejects it with an error indicating the maximum shot count.
4. **Given** a user provides shots with optional per-shot keyframe images, **When** they submit the request, **Then** each shot incorporates its keyframe image for visual continuity.
5. **Given** a multi-shot video completes, **When** the cost is calculated, **Then** it equals total duration (6 seconds x number of shots) multiplied by the per-second rate.

---

### User Story 6 - Generate a Video from an Image and Text Prompt (Priority: P3)

A user provides both a reference image and a text prompt to generate a video that starts from or is influenced by the provided image. This enables image-to-video workflows where users want to animate a still image.

**Why this priority**: Image-to-video is a valuable secondary capability but requires text-to-video to work first. It extends the core functionality without being essential for initial launch.

**Independent Test**: Can be tested by submitting a request with both a base64-encoded image and a text prompt, then verifying the resulting video is generated successfully.

**Acceptance Scenarios**:

1. **Given** a user provides a valid 1280x720 image and text prompt, **When** they submit a video generation request, **Then** the system accepts the request and generates a video incorporating the reference image.
2. **Given** a user provides an image with incorrect dimensions, **When** they submit the request, **Then** the system returns a clear error explaining the dimension requirements.

---

### Edge Cases

- What happens when the underlying video generation service fails mid-job? The system marks the job as "failed" with an error message and does not charge the user.
- What happens when the download URL expires before the user retrieves the video? The user can re-poll the job status to get a fresh download URL (as long as the video file hasn't been cleaned up by the retention policy).
- What happens when many video jobs are submitted simultaneously? The system enforces a configurable per-key concurrent job limit (default: 3). Requests exceeding the limit are rejected with a clear error. Beyond that, the upstream service handles its own throttling and the system returns appropriate rate limit errors if the upstream rejects the request.
- What happens when the retention policy deletes a completed video? The job status changes to indicate the video is no longer available, with a clear message about the retention period.
- What happens when the sidecar service restarts while jobs are in progress? The system recovers by re-checking upstream job status on the next poll — no in-memory state is required for job tracking.
- What happens when a user requests an invalid duration (not a multiple of 6, or outside 6-120 range)? The system returns a validation error before submitting to the upstream service.
- What happens when a multi-shot request has shots with prompts exceeding 512 characters? The system returns a validation error identifying which shot(s) exceed the limit.
- What happens when a multi-shot request mixes shots with and without keyframe images? This is allowed — keyframe images are optional per shot.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST accept video generation requests in two modes: single-shot (one text prompt with optional duration) and multi-shot (array of per-shot prompts).
- **FR-002**: For single-shot mode, system MUST validate that duration is a multiple of 6 seconds, between 6 and 120 seconds inclusive, defaulting to 6 seconds if not specified.
- **FR-003**: For multi-shot mode, system MUST accept an array of 2 to 20 shots, each with a text prompt (up to 512 characters) and optional keyframe image. Total duration is calculated as 6 seconds per shot.
- **FR-004**: System MUST authenticate all requests using the same virtual API keys used for text and image generation.
- **FR-005**: System MUST check the requesting key's remaining budget against the estimated video cost before starting generation.
- **FR-006**: System MUST enforce a configurable per-key limit on concurrent in-progress video jobs, defaulting to 3. Requests exceeding the limit MUST be rejected with an error indicating the current count and limit.
- **FR-007**: System MUST return a job identifier immediately upon accepting a video generation request.
- **FR-008**: System MUST provide a status endpoint that returns current job state (in_progress, completed, failed) and a download URL when completed.
- **FR-009**: System MUST provide a list endpoint that returns recent jobs scoped to the requesting API key.
- **FR-010**: System MUST record video generation costs in the same spend tracking system used for text and image generation, so costs appear in unified spend reports.
- **FR-011**: System MUST calculate video cost as duration in seconds multiplied by the per-second rate ($0.08).
- **FR-012**: System MUST store generated videos with automatic cleanup after 7 days.
- **FR-013**: System MUST provide time-limited download URLs (1 hour expiry) for completed videos.
- **FR-014**: System MUST regenerate download URLs on subsequent status polls if the video file still exists.
- **FR-015**: System MUST accept an optional reference image (base64-encoded, 1280x720, PNG or JPEG) for image-to-video generation in both single-shot and as per-shot keyframes in multi-shot mode.
- **FR-016**: System MUST validate image dimensions and format before submitting to the video generation service.
- **FR-017**: System MUST scope job visibility to the requesting API key — users cannot see or access jobs from other keys.
- **FR-018**: System MUST not charge the user for failed video generation jobs.
- **FR-019**: System MUST be accessible through the same network entry point (tunnel) as existing services.
- **FR-020**: System MUST report its health status through the existing infrastructure health checks.

### Key Entities

- **Video Job**: Represents a single video generation request. Key attributes: job ID, API key (hashed), mode (single-shot or multi-shot), prompt(s), duration, number of shots, status, creation time, completion time, cost, error message (if failed), storage location.
- **Video File**: The generated video output. Key attributes: storage path, file format (MP4), resolution (1280x720), frame rate (24fps), duration, retention expiry date.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can submit a video generation request and receive a job ID within 2 seconds.
- **SC-002**: Users can download a completed 6-second video within 3 minutes of submission (including generation time).
- **SC-003**: Video generation costs appear in spend reports within 1 minute of job completion.
- **SC-004**: Budget enforcement rejects over-budget requests before any generation begins, with zero false charges.
- **SC-005**: All video endpoints authenticate using existing API keys with no additional credential setup required.
- **SC-006**: Generated videos are automatically cleaned up after the retention period with no manual intervention.
- **SC-007**: The video generation service recovers from restarts without losing track of in-progress jobs.
- **SC-008**: Admin spend reports show video costs alongside text and image costs in a unified view.

## Clarifications

### Session 2026-03-16

- Q: Should there be a per-key limit on concurrent in-progress video jobs? → A: Yes, configurable per-key with a default of 3.
- Q: Should multi-shot video generation (per-shot prompts with manual narrative control) be in scope? → A: Yes, include in initial scope. Multi-shot supports 2-20 shots at 6 seconds each, with per-shot text prompts (up to 512 chars) and optional keyframe images.

## Assumptions

- Per-second video generation pricing remains at $0.08 for 720p video.
- Video generation is only available in one region (us-east-1) — the system makes cross-region calls as needed.
- Video output is always 1280x720 at 24fps in MP4 format — these are fixed by the upstream service.
- The existing EC2 instance has sufficient resources to run the sidecar service alongside existing services.
- 7-day video retention is sufficient — users are expected to download videos promptly.
- 1-hour presigned URL expiry balances security with usability.
- Job metadata (ID, status, prompt, cost) is stored persistently; the sidecar does not rely on in-memory state for job tracking.
- The network tunnel can be configured to route video-specific paths to the sidecar service.
