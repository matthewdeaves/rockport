variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "domain" {
  description = "Full domain for the LiteLLM proxy (e.g. llm.example.com)"
  type        = string
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
  description = "Email address for budget alerts"
  type        = string
}

variable "litellm_version" {
  description = "LiteLLM version to install"
  type        = string
  default     = "1.82.1"
}

variable "cloudflared_version" {
  description = "Cloudflared version to install (pinned for stability)"
  type        = string
  default     = "2025.2.1"
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
