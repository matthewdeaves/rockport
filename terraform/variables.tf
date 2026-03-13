variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "domain" {
  description = "Full domain for the LiteLLM proxy (e.g. llm.matthewdeaves.com)"
  type        = string
  default     = "llm.matthewdeaves.com"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain"
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "tunnel_subdomain" {
  description = "Subdomain for the Cloudflare Tunnel (e.g. llm)"
  type        = string
  default     = "llm"
}

variable "budget_alert_email" {
  description = "Email address for AWS budget alerts"
  type        = string
  default     = "matt@matthewdeaves.com"
}
