# Future Ideas

## Additional rate limiting at the Cloudflare edge

Cloudflare Rate Limiting rules could throttle requests before they reach the tunnel, protecting against brute-force key guessing or abuse from a single IP. The current setup relies on LiteLLM's per-key rate limits (60 RPM / 200K TPM), which only apply after the request reaches the proxy. Edge rate limiting would reduce load on the instance during an attack.

## SNS notifications on instance stop

When the idle-stop Lambda stops the instance, it could publish to an SNS topic to notify the operator. Currently stops are visible in CloudWatch but don't trigger a notification. Useful if you want a push alert when the instance goes idle.

## Pipeline Orchestration (Canvas-to-Reel in One Call)

A `POST /v1/videos/pipeline` endpoint that accepts a character description, reference image, and list of shots, then orchestrates: (1) Nova Canvas IMAGE_VARIATION per shot with consistent seed/cfgScale to generate per-shot frames, (2) Nova Reel MULTI_SHOT_MANUAL with the generated frames. Eliminates the multi-step manual workflow. Deferred because it's the most complex and opinionated feature — better to prove the building blocks first.

## Nova Lite Prompt Rewriting

Opt-in parameter on `/v1/videos/generations` that calls Nova Lite (LLM) to convert rough animation intent into an optimised Nova Reel prompt before submission. Follows the AWS storyboarding pipeline pattern. Excluded because it adds latency (~2-5s), cost (LLM invocation), and an LLM dependency to what should be a video endpoint.

## Cloudflare Access with identity provider

The current setup uses a service token (machine-to-machine). For broader team access, you could add an identity provider (e.g. GitHub OAuth, Google) so team members authenticate via browser before accessing the proxy. Not needed for the current single-operator setup but useful if sharing access more broadly.
