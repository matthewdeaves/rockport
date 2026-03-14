#!/bin/bash
# shellcheck disable=SC2154  # Variables are injected by Terraform templatefile()
set -euo pipefail

LOG_FILE="/var/log/rockport-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Rockport bootstrap started at $(date) ==="

REGION="${region}"
MASTER_KEY_SSM_PATH="${master_key_ssm_path}"
TUNNEL_TOKEN_SSM_PATH="${tunnel_token_ssm_path}"
LITELLM_VERSION="${litellm_version}"
CLOUDFLARED_VERSION="${cloudflared_version}"

# --- Swap ---
if [[ ! -f /swapfile ]]; then
  echo "Creating swap..."
  dd if=/dev/zero of=/swapfile bs=1M count=512
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
  sysctl vm.swappiness=10
  echo "vm.swappiness=10" >> /etc/sysctl.d/99-rockport.conf
else
  echo "Swap already exists, skipping."
fi

# --- PostgreSQL 15 ---
echo "Installing PostgreSQL 15..."
dnf install -y postgresql15-server postgresql15

if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
  /usr/bin/postgresql-setup --initdb

  # Apply tuning config
  cat > /var/lib/pgsql/data/postgresql-tuning.conf <<'PGCONF'
shared_buffers = 64MB
work_mem = 4MB
effective_cache_size = 256MB
maintenance_work_mem = 32MB
max_connections = 30
PGCONF

  echo "include = 'postgresql-tuning.conf'" >> /var/lib/pgsql/data/postgresql.conf

  # Keep peer auth for postgres superuser, use md5 for litellm_user (local + TCP)
  sed -i '/^local\s\+all\s\+all\s\+peer/i local all litellm_user md5' /var/lib/pgsql/data/pg_hba.conf
  sed -i '/^host\s\+all\s\+all\s\+127.0.0.1/i host all litellm_user 127.0.0.1/32 md5' /var/lib/pgsql/data/pg_hba.conf
else
  echo "PostgreSQL already initialized, skipping initdb."
fi

# Systemd override for Restart=always
mkdir -p /etc/systemd/system/postgresql.service.d
cat > /etc/systemd/system/postgresql.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF

systemctl daemon-reload
systemctl enable postgresql
systemctl start postgresql

# Create litellm database and user — suppress secrets from log
echo "Creating database and user..."
{
  # Check if DB password already exists in SSM (instance was restored)
  EXISTING_PASSWORD=$(aws ssm get-parameter \
    --name "/rockport/db-password" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION" 2>/dev/null) || EXISTING_PASSWORD=""

  if [[ -n "$EXISTING_PASSWORD" ]]; then
    DB_PASSWORD="$EXISTING_PASSWORD"
    echo "Reusing existing DB password from SSM." >&2
  else
    DB_PASSWORD=$(openssl rand -hex 16)
    echo "Generated new DB password." >&2
  fi

  # Create user and database idempotently
  # Password is hex-only (openssl rand -hex) so single-quote SQL injection is not possible
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='litellm_user'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER litellm_user WITH PASSWORD '$DB_PASSWORD'"
    echo "Created litellm_user." >&2
  else
    # Update password in case it changed
    sudo -u postgres psql -c "ALTER USER litellm_user WITH PASSWORD '$DB_PASSWORD'"
    echo "Updated litellm_user password." >&2
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm_user;"
    echo "Created litellm database." >&2
  else
    echo "Database litellm already exists." >&2
  fi

  sudo -u postgres psql -d litellm -c "GRANT ALL ON SCHEMA public TO litellm_user;"

  DATABASE_URL="postgresql://litellm_user:$DB_PASSWORD@localhost:5432/litellm"

  # Store DB password in SSM for recovery
  if [[ -z "$EXISTING_PASSWORD" ]]; then
    aws ssm put-parameter \
      --name "/rockport/db-password" \
      --value "$DB_PASSWORD" \
      --type SecureString \
      --overwrite \
      --region "$REGION"
    echo "DB password stored in SSM." >&2
  fi
} > /dev/null
echo "Database and user ready."

# --- Fetch secrets from SSM ---
echo "Fetching secrets from SSM..."
MASTER_KEY=$(aws ssm get-parameter \
  --name "$MASTER_KEY_SSM_PATH" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION") || { echo "FATAL: Failed to fetch master key from SSM"; exit 1; }

TUNNEL_TOKEN=$(aws ssm get-parameter \
  --name "$TUNNEL_TOKEN_SSM_PATH" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION") || { echo "FATAL: Failed to fetch tunnel token from SSM"; exit 1; }

# Validate secrets are not empty
[[ -n "$MASTER_KEY" ]] || { echo "FATAL: Master key is empty"; exit 1; }
[[ -n "$TUNNEL_TOKEN" ]] || { echo "FATAL: Tunnel token is empty"; exit 1; }
echo "Secrets fetched from SSM."

# --- LiteLLM ---
echo "Installing LiteLLM..."
dnf install -y python3.11 python3.11-pip libatomic
pip3.11 install "litellm[proxy]==$LITELLM_VERSION" prisma

# Create litellm user with home directory (needed for prisma cache)
if ! id litellm &>/dev/null; then
  useradd --system --create-home --shell /usr/sbin/nologin litellm
fi

# Generate prisma client AS the litellm user so binary paths resolve correctly.
# prisma generate hardcodes the running user's cache paths into the generated client,
# so it must run as the same user that will run litellm at runtime.
chown -R litellm:litellm /usr/local/lib/python3.11/site-packages/prisma
HOME=/home/litellm sudo -u litellm -E prisma generate \
  --schema /usr/local/lib/python3.11/site-packages/litellm/proxy/schema.prisma

# Config
mkdir -p /etc/litellm
cat > /etc/litellm/config.yaml <<'LITELLMCONF'
${litellm_config}
LITELLMCONF
chown -R litellm:litellm /etc/litellm

# Cache/data directory for LiteLLM runtime
mkdir -p /var/lib/litellm
chown litellm:litellm /var/lib/litellm

# Env file — written inside subshell with restrictive umask to prevent brief exposure
(
  umask 077
  cat > /etc/litellm/env <<ENVEOF
DATABASE_URL=$DATABASE_URL
LITELLM_MASTER_KEY=$MASTER_KEY
ENVEOF
)
chown litellm:litellm /etc/litellm/env

# Systemd unit
cat > /etc/systemd/system/litellm.service <<'LITELLMSVC'
${litellm_service}
LITELLMSVC

# --- Cloudflared ---
echo "Installing cloudflared..."
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64" \
  -o /tmp/cloudflared
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64.sha256" \
  -o /tmp/cloudflared.sha256

# Verify checksum
expected_hash=$(awk '{print $1}' /tmp/cloudflared.sha256)
actual_hash=$(sha256sum /tmp/cloudflared | awk '{print $1}')
if [[ "$expected_hash" != "$actual_hash" ]]; then
  echo "FATAL: cloudflared checksum mismatch! Expected=$expected_hash Actual=$actual_hash"
  exit 1
fi
mv /tmp/cloudflared /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
rm -f /tmp/cloudflared.sha256
echo "cloudflared installed and verified."

# Create cloudflared user
if ! id cloudflared &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared
fi

# Env file — restrictive umask
(
  umask 077
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/env <<ENVEOF
TUNNEL_TOKEN=$TUNNEL_TOKEN
ENVEOF
)
chown cloudflared:cloudflared /etc/cloudflared/env

# Systemd unit
cat > /etc/systemd/system/cloudflared.service <<'CFLDSVC'
${cloudflared_service}
CFLDSVC

# --- Start services ---
echo "Starting services..."
systemctl daemon-reload
systemctl enable litellm cloudflared
systemctl start litellm
systemctl start cloudflared

echo "=== Rockport bootstrap completed at $(date) ==="
