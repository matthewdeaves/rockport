# Contract: Key Management with Model Restrictions

## Create Claude Code Key

`rockport setup-claude` or `rockport key create <name> --claude-only`

Calls LiteLLM `/key/generate` with:

```json
{
  "key_alias": "<name>",
  "models": [
    "claude-opus-4-6",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001",
    "claude-sonnet-4-5-20250929",
    "claude-opus-4-5-20251101"
  ]
}
```

**Result**: Key can only access Anthropic models. `/v1/models` returns only these models. Image generation calls are rejected.

## Create General Key

`rockport key create <name>` (no flags)

Calls LiteLLM `/key/generate` with:

```json
{
  "key_alias": "<name>"
}
```

**Result**: Key has access to all configured models (chat + image). `/v1/models` returns everything.

## Create Key with Budget

`rockport key create <name> --budget 5`

Same as above but adds budget constraints:

```json
{
  "key_alias": "<name>",
  "max_budget": 5,
  "budget_duration": "1d"
}
```

Flags can be combined: `rockport key create <name> --claude-only --budget 5`
