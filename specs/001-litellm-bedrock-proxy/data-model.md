# Data Model: LiteLLM Bedrock Proxy

**Date**: 2026-03-13
**Feature**: 001-litellm-bedrock-proxy

## Overview

All data is managed by LiteLLM's built-in Prisma ORM. Tables
are auto-created on first run. No custom schema or migrations.

## Entities (LiteLLM-managed)

### Virtual Key (LiteLLM_VerificationToken)

Represents an API key issued to a user. Created via
`/key/generate`, stored in PostgreSQL.

- **token** (string, primary key): The `sk-...` key value
- **key_name** (string, optional): Human-readable label
- **user_id** (string, optional): Associated user identifier
- **max_budget** (float, optional): Spend limit in USD
- **spend** (float): Current accumulated spend
- **models** (array, optional): Allowed models (empty = all)
- **rpm_limit** (int, optional): Requests per minute cap
- **tpm_limit** (int, optional): Tokens per minute cap
- **expires** (datetime, optional): Key expiration timestamp
- **blocked** (boolean): Whether key is temporarily disabled

### User (LiteLLM_UserTable)

Optional user record for grouping keys and tracking spend.

- **user_id** (string, primary key): Unique identifier
- **max_budget** (float, optional): User-level spend limit
- **spend** (float): Accumulated spend across all keys

### Config (LiteLLM_Config)

Runtime configuration stored in DB (supplements config.yaml).

- **param_name** (string, primary key): Setting name
- **param_value** (string): Setting value

## External State (not in PostgreSQL)

### LiteLLM config.yaml

Defines model routing. Stored on disk at `/etc/litellm/config.yaml`.
Backed up via EBS snapshots.

- **model_list**: Array of model definitions (alias → Bedrock ID)
- **general_settings**: Master key reference, database URL
- **litellm_settings**: Feature flags (disable UI, logging level)

### SSM Parameters

- `/rockport/master-key`: LiteLLM master key (SecureString)
- `/rockport/tunnel-token`: Cloudflare Tunnel token (SecureString)

## Relationships

```
Admin (master key holder)
  └── creates → Virtual Keys
                  └── authenticates → Users
                                       └── sends requests → Models (Bedrock)
```

## Notes

- LiteLLM auto-creates all tables via Prisma on first startup.
- No custom migrations or schema management needed.
- PostgreSQL data protected by daily EBS snapshots (7-day
  retention via DLM).
