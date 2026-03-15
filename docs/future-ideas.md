# Future Ideas

## Cloudflare Access for pre-authentication

For an additional security layer, you can put a Cloudflare Access application in front of the tunnel. This requires authentication before traffic reaches LiteLLM.

**Email verification** — Gate the domain behind a one-time-password sent to allowed email addresses. Any request without a valid Cloudflare Access JWT is blocked at the edge. The downside is that Claude Code doesn't natively handle Cloudflare Access authentication, so you'd need a service token passed as a header, or use `cloudflared access` to create a local tunnel on the client side.

**mTLS (mutual TLS)** — Require client certificates signed by a CA you upload. Only clients presenting a valid certificate can connect. Strongest option but adds certificate distribution and rotation complexity.

**Service tokens** — Create a Cloudflare Access service token (client ID + secret) and configure Claude Code to send it as headers. Adds a second credential layer without mTLS complexity. Configure via Cloudflare Zero Trust dashboard > Access > Applications.

For a personal or small-team proxy where the API keys are closely held, the current setup (key auth + Cloudflare DDoS protection + no inbound ports) is sufficient. Cloudflare Access adds value when sharing access more broadly or for compliance requirements.
