# Optional Bedrock Guardrail for content filtering, PII masking, and profanity blocking.
# Disabled by default — set enable_guardrails = true in terraform.tfvars to activate.

resource "aws_bedrock_guardrail" "rockport" {
  count = var.enable_guardrails ? 1 : 0

  name                      = "rockport-guard"
  blocked_input_messaging   = "Your request was blocked by the content filter. Please rephrase your message."
  blocked_outputs_messaging = "The response was blocked by the content filter."
  description               = "Rockport content filtering guardrail — violence, hate, insults, PII masking, profanity"

  content_policy_config {
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "HATE"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }
  }

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }

  tags = local.common_tags
}
