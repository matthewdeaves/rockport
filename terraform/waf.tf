# Cloudflare WAF rule — allowlist only the paths Claude Code and the admin CLI need.
# Everything else is blocked at the edge before reaching LiteLLM.
#
# Allowed paths:
#   /v1/chat/completions, /v1/messages, /v1/models  — Claude Code inference
#   /v1/images/generations                           — Image generation (text-to-image + image-to-image)
#   /v1/images/edits                                 — Stability AI image edit operations (via LiteLLM)
#   /v1/images/*                                     — Nova Canvas sidecar (variations, background-removal, outpaint)
#   /chat/completions, /completions, /models          — OpenAI-compatible aliases
#   /v1/completions, /embeddings, /v1/embeddings      — additional API endpoints
#   /key/*, /user/*, /team/*, /spend/*, /global/spend* — admin CLI management
#   /health                                             — health check (exact match only)
#   /budget/*                                          — budget management
#   /model/info, /v1/model/info, /model_group/info     — model metadata

resource "cloudflare_ruleset" "waf_block_sensitive" {
  zone_id     = var.cloudflare_zone_id
  name        = "Rockport path allowlist"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  description = "Block all paths except those needed by Claude Code and admin CLI"

  rules = [{
    action      = "block"
    enabled     = true
    description = "Block non-allowlisted paths"
    expression = join(" and ", [
      # Only apply to Rockport's subdomain (not other apps on this zone)
      "(http.host eq \"llm.matthewdeaves.com\")",
      # Not an allowed API inference path
      "not starts_with(http.request.uri.path, \"/v1/chat/completions\")",
      "not starts_with(http.request.uri.path, \"/v1/messages\")",
      "not starts_with(http.request.uri.path, \"/v1/models\")",
      "not starts_with(http.request.uri.path, \"/v1/completions\")",
      "not starts_with(http.request.uri.path, \"/v1/embeddings\")",
      "not starts_with(http.request.uri.path, \"/v1/images/generations\")",
      "not starts_with(http.request.uri.path, \"/v1/videos\")",
      "not starts_with(http.request.uri.path, \"/v1/images/\")",
      "not starts_with(http.request.uri.path, \"/chat/completions\")",
      "not starts_with(http.request.uri.path, \"/completions\")",
      "not starts_with(http.request.uri.path, \"/models\")",
      "not starts_with(http.request.uri.path, \"/embeddings\")",
      # Not an admin CLI path
      "not starts_with(http.request.uri.path, \"/key/\")",
      "not starts_with(http.request.uri.path, \"/user/\")",
      "not starts_with(http.request.uri.path, \"/team/\")",
      "not starts_with(http.request.uri.path, \"/spend/\")",
      "not starts_with(http.request.uri.path, \"/global/spend\")",
      "not starts_with(http.request.uri.path, \"/budget/\")",
      "not starts_with(http.request.uri.path, \"/model/info\")",
      "not starts_with(http.request.uri.path, \"/v1/model/info\")",
      "not starts_with(http.request.uri.path, \"/model_group/info\")",
      # Not a health check (exact match — /health/readiness etc. leak version info)
      "http.request.uri.path ne \"/health\"",
    ])
  }]
}
