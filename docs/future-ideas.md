# Future Ideas

## Additional rate limiting at the Cloudflare edge

Cloudflare Rate Limiting rules could throttle requests before they reach the tunnel, protecting against brute-force key guessing or abuse from a single IP. The current setup relies on LiteLLM's per-key rate limits (60 RPM / 200K TPM), which only apply after the request reaches the proxy. Edge rate limiting would reduce load on the instance during an attack.

## SNS notifications on instance stop

When the idle-stop Lambda stops the instance, it could publish to an SNS topic to notify the operator. Currently stops are visible in CloudWatch but don't trigger a notification. Useful if you want a push alert when the instance goes idle.

## Cloudflare Access with identity provider

The current setup uses a service token (machine-to-machine). For broader team access, you could add an identity provider (e.g. GitHub OAuth, Google) so team members authenticate via browser before accessing the proxy. Not needed for the current single-operator setup but useful if sharing access more broadly.
