#!/usr/bin/env bash
# scripts/install-litellm.sh — install or upgrade LiteLLM + prisma on the instance.
#
# Single source of truth for the pip/prisma sequence, run as root:
#   - first boot: bootstrap.sh (from the deploy artifact)
#   - later:      rockport.sh upgrade --litellm (via SSM, from the same artifact)
#
# Usage: install-litellm.sh <litellm-version>
# Requires: python3.11 + pip3.11, the `litellm` user with HOME=/var/lib/litellm,
#           DATABASE_URL in the environment or in /etc/litellm/env.

set -e
VERSION="${1:?usage: install-litellm.sh <litellm-version>}"
SP=/usr/local/lib/python3.11/site-packages
SCHEMA="$SP/litellm/proxy/schema.prisma"

pip3.11 install -q "litellm[proxy]==$VERSION" "prisma==0.11.0"

# prisma generate hardcodes $HOME/.cache paths into the generated client, so it
# must run as the litellm user (HOME=/var/lib/litellm — accessible under
# ProtectHome=yes, unlike /home).
chown -R litellm:litellm "$SP/prisma" "$SP/litellm_proxy_extras/migrations"
sudo -u litellm prisma generate --schema "$SCHEMA"

# Prisma expects migrations/ next to the schema; LiteLLM ships them in
# litellm_proxy_extras, so symlink. Applying them here (rather than letting
# LiteLLM baseline them at startup) avoids ~10s × 100+ migrations on first boot.
mkdir -p "$SP/litellm/proxy/prisma"
ln -sfn "$SP/litellm_proxy_extras/migrations" "$SP/litellm/proxy/prisma/migrations"

if [ -z "${DATABASE_URL:-}" ] && [ -r /etc/litellm/env ]; then
  DATABASE_URL=$(sed -n 's/^DATABASE_URL=//p' /etc/litellm/env)
fi
[ -n "${DATABASE_URL:-}" ] || { echo "install-litellm: DATABASE_URL not set" >&2; exit 1; }
sudo -u litellm DATABASE_URL="$DATABASE_URL" prisma migrate deploy --schema "$SCHEMA"

echo "LiteLLM $(pip3.11 show litellm 2>/dev/null | sed -n 's/^Version: //p') installed, migrations applied"
