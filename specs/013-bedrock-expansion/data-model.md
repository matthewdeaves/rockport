# Data Model: Rockport Bedrock Expansion

**Date**: 2026-03-22 | **Branch**: `013-bedrock-expansion`

## Overview

This feature adds no new data stores or tables. All data flows through existing LiteLLM infrastructure (PostgreSQL for spend tracking, config YAML for model routing). The "data model" here describes the configuration entities and their relationships.

## Entities

### Model Entry (litellm-config.yaml)

Defines a client-facing model name mapped to a Bedrock model ID.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `model_name` | string | yes | Client-facing model name (e.g., `llama4-scout`) |
| `litellm_params.model` | string | yes | LiteLLM model ID (e.g., `bedrock/us.meta.llama4-scout-17b-instruct-v1:0`) |
| `litellm_params.aws_region_name` | string | yes | AWS region for API calls |
| `litellm_params.cache_control_injection_points` | list | no | Server-side cache injection config |
| `model_info.mode` | string | no | Only for non-chat models (`image_generation`, `image_edit`) |

**New entries** (7 models):

| model_name | litellm model ID | region |
|-----------|-----------------|--------|
| `llama4-scout` | `bedrock/us.meta.llama4-scout-17b-instruct-v1:0` | us-east-1 |
| `llama4-maverick` | `bedrock/us.meta.llama4-maverick-17b-instruct-v1:0` | us-east-1 |
| `nova-2-lite` | `bedrock/eu.amazon.nova-2-lite-v1:0` | eu-west-2 |
| `mistral-large-3` | `bedrock/mistral.mistral-large-3-675b-instruct` | eu-west-2 |
| `ministral-8b` | `bedrock/mistral.ministral-3-8b-instruct` | eu-west-2 |
| `gpt-oss-120b` | `bedrock/openai.gpt-oss-120b-1:0` | eu-west-2 |
| `gpt-oss-20b` | `bedrock/openai.gpt-oss-20b-1:0` | eu-west-2 |

### Guardrail Config (litellm-config.yaml)

Optional section defining Bedrock Guardrails integration.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `guardrail_name` | string | yes | Reference name used in requests |
| `litellm_params.guardrail` | string | yes | Provider type, always `bedrock` |
| `litellm_params.mode` | enum | yes | `pre_call`, `post_call`, or `during_call` |
| `litellm_params.guardrailIdentifier` | string | yes | Bedrock guardrail ID (from Terraform output) |
| `litellm_params.guardrailVersion` | string | yes | Version number or `DRAFT` |
| `litellm_params.aws_region_name` | string | yes | Region where guardrail is deployed |
| `litellm_params.default_on` | bool | no | If true, runs on every request |
| `litellm_params.mask_request_content` | bool | no | PII masking on input |
| `litellm_params.mask_response_content` | bool | no | PII masking on output |

### Bedrock Guardrail (Terraform resource)

AWS resource defining content filtering policies.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable name |
| `blocked_input_messaging` | string | yes | Message shown when input is blocked |
| `blocked_outputs_messaging` | string | yes | Message shown when output is blocked |
| `content_policy_config` | object | no | Violence, hate, insults, sexual, misconduct filters with strength levels |
| `sensitive_information_policy_config` | object | no | PII entity detection (EMAIL, PHONE, SSN, etc.) with ANONYMIZE or BLOCK |
| `word_policy_config` | object | no | Managed profanity list and custom word filters |
| `topic_policy_config` | object | no | Custom denied topics |
| `contextual_grounding_policy_config` | object | no | Hallucination detection thresholds |

**Output**: `guardrail_id` → used as `guardrailIdentifier` in LiteLLM config

### IAM Policy Statement (Terraform)

New model family patterns added to existing `bedrock_invoke` policy.

| Statement | Regions | New Patterns |
|-----------|---------|-------------|
| `InvokeEUCrossRegionModels` | EU regions | `mistral.*`, `openai.gpt-oss*` |
| `InvokeUSModels` | US regions | `meta.llama4*` |
| New: `ApplyGuardrail` | eu-west-2 | `arn:aws:bedrock:*:*:guardrail/*` (conditional) |

## Relationships

```
litellm-config.yaml
├── model_list[]
│   ├── Model Entry (existing Claude, Nova, etc.)
│   └── Model Entry (new: Llama 4, Nova 2, Mistral, GPT-OSS)
├── guardrails[] (optional)
│   └── Guardrail Config → references Bedrock Guardrail (Terraform)
└── litellm_settings
    ├── drop_params: true (existing)
    └── modify_params: true (new — for extended thinking multi-turn)

terraform/main.tf
├── aws_iam_role_policy.bedrock_invoke
│   └── Updated with new model family patterns
└── aws_bedrock_guardrail (new, optional)
    └── aws_bedrock_guardrail_version
```

## State Transitions

No new state machines. All request processing follows existing LiteLLM flow:

```
Request → Auth (key check) → Guardrail pre_call (if configured)
  → Model routing → Bedrock Converse API → Guardrail post_call (if configured)
  → Response (with usage including cache metrics and thinking blocks)
```
