resource "cloudflare_zero_trust_tunnel_cloudflared" "rockport" {
  account_id    = var.cloudflare_account_id
  name          = "rockport"
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

resource "random_password" "tunnel_secret" {
  length  = 32
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "rockport" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.rockport.id

  config = {
    ingress = [
      {
        hostname = var.domain
        path     = "/v1/videos*"
        service  = "http://localhost:4001"
      },
      {
        hostname = var.domain
        path     = "/v1/images/generations*"
        service  = "http://localhost:4000"
      },
      {
        # Stability AI image edit operations via LiteLLM native /v1/images/edits
        hostname = var.domain
        path     = "/v1/images/edits*"
        service  = "http://localhost:4000"
      },
      {
        # Nova Canvas sidecar endpoints: variations, background-removal, outpaint
        hostname = var.domain
        path     = "/v1/images/*"
        service  = "http://localhost:4001"
      },
      {
        hostname = var.domain
        service  = "http://localhost:4000"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "tunnel" {
  zone_id = var.cloudflare_zone_id
  name    = var.tunnel_subdomain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.rockport.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "rockport" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.rockport.id
}

resource "aws_ssm_parameter" "tunnel_token" {
  name  = "/rockport/tunnel-token"
  type  = "SecureString"
  value = data.cloudflare_zero_trust_tunnel_cloudflared_token.rockport.token

  tags = local.common_tags
}
