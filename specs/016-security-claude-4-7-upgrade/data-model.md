# Phase 1 — Data Model

## Summary

**No schema changes.** Both the LiteLLM Prisma-managed tables and the sidecar's `rockport_video_jobs` table stay at their current shapes. This feature does not add, rename, drop, or re-type any column, index, or foreign key.

## Entities touched (behavior-only, no schema delta)

### `rockport_video_jobs` (existing)

Fields (unchanged):
- `id` UUID, primary key
- `api_key_hash` TEXT — scope of the per-key concurrency counter
- `invocation_arn` TEXT, nullable — Bedrock async-invoke ARN (null for `pending`)
- `model` TEXT — `nova-reel` | `ray2` | future provider
- `mode` TEXT — single-shot, multi-shot, multi-shot-automated
- `prompt` TEXT
- `num_shots` INT, nullable
- `duration_seconds` INT
- `resolution` TEXT, nullable
- `cost` NUMERIC
- `status` TEXT — `pending` | `in_progress` | `completed` | `failed`
- `created_at` TIMESTAMPTZ

Behavioral change:

- The invariant "per-key concurrency is counted across **all** models and regions" is now explicitly documented via a code comment adjacent to the SELECT statement in `sidecar/db.py`. The SQL itself is unchanged (it already scopes solely by `api_key_hash`).
- State transitions unchanged: `pending` → `in_progress` → (`completed` | `failed`).

### LiteLLM `LiteLLM_VerificationToken` / `LiteLLM_SpendLogs` (existing)

Fields (unchanged). Consumed via LiteLLM's API only — this project does not write raw SQL against them.

Behavioral change:

- With LiteLLM 1.83.7's cache-token double-count fix (PR #25517 in the upstream project), values in `LiteLLM_SpendLogs.response_cost` for streaming Claude requests that use `cache_control_injection_points` will more accurately reflect the billed amount. No migration required.

## No new entities

This feature introduces no new tables, views, or stored procedures.
