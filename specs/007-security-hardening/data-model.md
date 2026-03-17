# Data Model: Security Hardening

No new data entities are introduced by this feature. All changes are to infrastructure configuration, service hardening, and a concurrency fix in the existing database layer.

## Existing Entities (unchanged)

- **rockport_video_jobs**: Existing table tracking video generation jobs. The TOCTOU fix (R6) changes how rows are inserted (atomic check+insert) but does not alter the schema.

## New Configuration Entities

- **Cloudflare Access Service Token**: A credential pair (Client ID + Client Secret) managed by Terraform. Not stored in the database — exists in Cloudflare's control plane and output as sensitive Terraform outputs. Must be distributed to all API clients.

- **CloudWatch Alarm (Lambda errors)**: A monitoring resource in AWS CloudWatch. No database storage — exists in AWS control plane, managed by Terraform.
