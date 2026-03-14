variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "Region must be a valid AWS region (e.g. eu-west-2, us-east-1)."
  }
}

variable "domain" {
  description = "Full domain for the LiteLLM proxy (e.g. llm.example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.domain))
    error_message = "Domain must be a valid FQDN (e.g. llm.example.com)."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "Cloudflare Zone ID must be a 32-character hex string."
  }
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "Cloudflare Account ID must be a 32-character hex string."
  }
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
  description = "Email address for budget alerts"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.budget_alert_email))
    error_message = "Must be a valid email address."
  }
}

variable "litellm_version" {
  description = "LiteLLM version to install"
  type        = string
  default     = "1.82.2"
}

variable "cloudflared_version" {
  description = "Cloudflared version to install (pinned for stability)"
  type        = string
  default     = "2026.3.0"
}

variable "bedrock_daily_budget" {
  description = "Daily Bedrock spend limit in USD"
  type        = number
  default     = 10
}

variable "monthly_budget" {
  description = "Overall monthly AWS budget in USD (EC2, EBS, Bedrock, etc.)"
  type        = number
  default     = 30
}

variable "enable_idle_shutdown" {
  description = "Auto-stop EC2 instance after period of inactivity"
  type        = bool
  default     = true
}

variable "idle_timeout_minutes" {
  description = "Minutes of inactivity before auto-stopping the instance"
  type        = number
  default     = 30
}

variable "idle_threshold_bytes" {
  description = "Network traffic threshold in bytes below which instance is considered idle"
  type        = number
  default     = 500000
}
