# Cloudflare Access — pre-authenticate all requests at the edge using a service token.
# Requests without valid CF-Access-Client-Id / CF-Access-Client-Secret headers
# are blocked by Cloudflare before reaching the tunnel.

resource "cloudflare_zero_trust_access_service_token" "rockport" {
  account_id = var.cloudflare_account_id
  name       = "rockport-api"
}

resource "cloudflare_zero_trust_access_application" "rockport" {
  zone_id                   = var.cloudflare_zone_id
  name                      = "Rockport API"
  domain                    = var.domain
  type                      = "self_hosted"
  session_duration          = "24h"
  skip_interstitial         = true
  app_launcher_visible      = false
  service_auth_401_redirect = false

  policies = [{
    name     = "Require Rockport service token"
    decision = "non_identity"
    include  = [{ any_valid_service_token = {} }]
  }]
}

# --- Outputs (sensitive) ---

output "cf_access_client_id" {
  description = "Cloudflare Access service token Client ID — use as CF-Access-Client-Id header"
  value       = cloudflare_zero_trust_access_service_token.rockport.client_id
  sensitive   = true
}

output "cf_access_client_secret" {
  description = "Cloudflare Access service token Client Secret — use as CF-Access-Client-Secret header"
  value       = cloudflare_zero_trust_access_service_token.rockport.client_secret
  sensitive   = true
}
