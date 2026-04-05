# Cloudflare response header transform — inject security headers into proxied responses.
#
# Cloudflare adds HSTS and X-Content-Type-Options to its own responses (e.g. Access 403 pages)
# but NOT to responses proxied through the tunnel. This rule adds them to all proxied responses
# for the Rockport subdomain.

resource "cloudflare_ruleset" "response_headers" {
  zone_id     = var.cloudflare_zone_id
  name        = "Rockport security response headers"
  kind        = "zone"
  phase       = "http_response_headers_transform"
  description = "Add security headers to proxied responses"

  rules = [
    {
      action      = "rewrite"
      enabled     = true
      description = "Add HSTS and security headers to Rockport responses"
      expression  = "(http.host eq \"llm.matthewdeaves.com\")"
      action_parameters = {
        headers = {
          "Strict-Transport-Security" = {
            operation = "set"
            value     = "max-age=15552000"
          }
          "X-Content-Type-Options" = {
            operation = "set"
            value     = "nosniff"
          }
        }
      }
    },
  ]
}
