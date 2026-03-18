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

  validation {
    condition     = !can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
    error_message = "Graviton (ARM) instances are incompatible with Prisma. Use x86 instances (e.g. t3.small)."
  }
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
  default     = "1.82.3"
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

  validation {
    condition     = var.bedrock_daily_budget > 0
    error_message = "Daily budget must be greater than zero."
  }
}

variable "monthly_budget" {
  description = "Overall monthly AWS budget in USD (EC2, EBS, Bedrock, etc.)"
  type        = number
  default     = 30

  validation {
    condition     = var.monthly_budget > 0
    error_message = "Monthly budget must be greater than zero."
  }
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

  validation {
    condition     = var.idle_timeout_minutes >= 5
    error_message = "Idle timeout must be at least 5 minutes (Lambda checks every 5 minutes)."
  }
}

variable "idle_threshold_bytes" {
  description = "Network traffic threshold in bytes below which instance is considered idle"
  type        = number
  default     = 500000

  validation {
    condition     = var.idle_threshold_bytes >= 0
    error_message = "Idle threshold bytes must not be negative."
  }
}

variable "video_max_concurrent_jobs" {
  description = "Maximum concurrent video generation jobs per API key"
  type        = number
  default     = 3

  validation {
    condition     = var.video_max_concurrent_jobs >= 1
    error_message = "Must allow at least 1 concurrent video job per key."
  }
}
