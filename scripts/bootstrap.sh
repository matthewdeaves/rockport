#!/bin/bash
# shellcheck disable=SC2154  # Variables are injected by Terraform templatefile()
set -euo pipefail

LOG_FILE="/var/log/rockport-bootstrap.log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Rockport bootstrap started at $(date) ==="

REGION="${region}"
MASTER_KEY_SSM_PATH="${master_key_ssm_path}"
TUNNEL_TOKEN_SSM_PATH="${tunnel_token_ssm_path}"
LITELLM_VERSION="${litellm_version}"
CLOUDFLARED_VERSION="${cloudflared_version}"
CLOUDFLARED_SHA256="${cloudflared_sha256}"
ARTIFACTS_BUCKET="${artifacts_bucket}"

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
  # Increase UDP buffers for cloudflared QUIC tunnel (large request payloads)
  sysctl -w net.core.rmem_max=7500000
  sysctl -w net.core.wmem_max=7500000
  cat >> /etc/sysctl.d/99-rockport.conf <<SYSEOF
net.core.rmem_max=7500000
net.core.wmem_max=7500000
SYSEOF
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
password_encryption = scram-sha-256
PGCONF

  echo "include = 'postgresql-tuning.conf'" >> /var/lib/pgsql/data/postgresql.conf

  # Keep peer auth for postgres superuser, use scram-sha-256 for litellm_user (local + TCP)
  sed -i '/^local\s\+all\s\+all\s\+peer/i local all litellm_user scram-sha-256' /var/lib/pgsql/data/pg_hba.conf
  sed -i '/^host\s\+all\s\+all\s\+127.0.0.1/i host all litellm_user 127.0.0.1/32 scram-sha-256' /var/lib/pgsql/data/pg_hba.conf
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

# Cache/data directory for LiteLLM runtime — must exist before user creation
# so we can set it as the user's home directory
mkdir -p /var/lib/litellm

# Create litellm user with home at /var/lib/litellm (not /home/litellm).
# This ensures prisma generate caches binaries under /var/lib/litellm/.cache,
# which is accessible under ProtectHome=yes (only /home is blocked).
if ! id litellm &>/dev/null; then
  useradd --system --home-dir /var/lib/litellm --no-create-home --shell /usr/sbin/nologin litellm
fi
chown litellm:litellm /var/lib/litellm

# Generate prisma client AS the litellm user so binary paths resolve correctly.
# prisma generate hardcodes $HOME/.cache paths into the generated client.
chown -R litellm:litellm /usr/local/lib/python3.11/site-packages/prisma
chown -R litellm:litellm /usr/local/lib/python3.11/site-packages/litellm_proxy_extras/migrations
sudo -u litellm prisma generate \
  --schema /usr/local/lib/python3.11/site-packages/litellm/proxy/schema.prisma

# Apply all Prisma migrations now while DB is empty.
# This avoids the slow per-migration baseline resolve that LiteLLM does on
# startup when it finds tables but no migration history (~10s × 108 migrations).
# Prisma expects a migrations/ dir next to the schema; LiteLLM stores them in
# litellm_proxy_extras, so we symlink.
echo "Applying Prisma migrations..."
mkdir -p /usr/local/lib/python3.11/site-packages/litellm/proxy/prisma
ln -sfn /usr/local/lib/python3.11/site-packages/litellm_proxy_extras/migrations \
  /usr/local/lib/python3.11/site-packages/litellm/proxy/prisma/migrations
sudo -u litellm DATABASE_URL="$DATABASE_URL" prisma migrate deploy \
  --schema /usr/local/lib/python3.11/site-packages/litellm/proxy/schema.prisma
echo "Prisma migrations applied."

# --- Download deploy artifact from S3 ---
echo "Downloading deploy artifact from S3..."
aws s3 cp "s3://$ARTIFACTS_BUCKET/deploy/rockport-artifact.tar.gz" /tmp/rockport-artifact.tar.gz \
  --region "$REGION" || { echo "FATAL: Failed to download deploy artifact from S3"; exit 1; }

# Verify artifact integrity via SHA256 checksum
if aws s3 cp "s3://$ARTIFACTS_BUCKET/deploy/rockport-artifact.tar.gz.sha256" /tmp/rockport-artifact.tar.gz.sha256 \
  --region "$REGION" 2>/dev/null; then
  echo "Verifying artifact checksum..."
  (cd /tmp && sha256sum -c rockport-artifact.tar.gz.sha256) || {
    echo "FATAL: Artifact SHA256 checksum verification failed"
    exit 1
  }
  echo "Artifact checksum verified."
  rm -f /tmp/rockport-artifact.tar.gz.sha256
else
  echo "WARNING: No checksum file found, skipping integrity verification."
fi

# Extract config files
mkdir -p /etc/litellm
tar xzf /tmp/rockport-artifact.tar.gz -C /tmp rockport-artifact/
cp /tmp/rockport-artifact/config/litellm-config.yaml /etc/litellm/config.yaml
chown -R litellm:litellm /etc/litellm

# Env file — written inside subshell with restrictive umask to prevent brief exposure
(
  umask 077
  cat > /etc/litellm/env <<ENVEOF
DATABASE_URL=$DATABASE_URL
LITELLM_MASTER_KEY=$MASTER_KEY
NO_DOCS=True
NO_REDOC=True
ENVEOF
)
chown litellm:litellm /etc/litellm/env

# Systemd unit
cp /tmp/rockport-artifact/config/litellm.service /etc/systemd/system/litellm.service

# --- Video Generation Sidecar ---
echo "Installing video sidecar dependencies..."
if [[ -f /tmp/rockport-artifact/sidecar/requirements.lock ]]; then
  pip3.11 install --require-hashes -r /tmp/rockport-artifact/sidecar/requirements.lock
else
  pip3.11 install psycopg2-binary Pillow httpx
fi

echo "Setting up video sidecar..."
mkdir -p /opt/rockport-video
cp /tmp/rockport-artifact/sidecar/*.py /opt/rockport-video/
chown -R litellm:litellm /opt/rockport-video

# Create video jobs table in litellm database
sudo -u postgres psql -d litellm -c "
  CREATE TABLE IF NOT EXISTS rockport_video_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    api_key_hash VARCHAR(128) NOT NULL,
    invocation_arn VARCHAR(512) UNIQUE,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    mode VARCHAR(20) NOT NULL,
    prompt TEXT NOT NULL,
    num_shots INTEGER NOT NULL DEFAULT 1,
    duration_seconds INTEGER NOT NULL,
    cost DECIMAL(10,4) DEFAULT 0,
    s3_uri VARCHAR(512),
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
  );
  CREATE INDEX IF NOT EXISTS idx_video_jobs_api_key_hash ON rockport_video_jobs (api_key_hash);
  CREATE INDEX IF NOT EXISTS idx_video_jobs_status ON rockport_video_jobs (status);
  CREATE INDEX IF NOT EXISTS idx_video_jobs_created_at ON rockport_video_jobs (created_at);
  ALTER TABLE rockport_video_jobs OWNER TO litellm_user;
  ALTER TABLE rockport_video_jobs ADD COLUMN IF NOT EXISTS model VARCHAR(30) NOT NULL DEFAULT 'nova-reel';
  ALTER TABLE rockport_video_jobs ADD COLUMN IF NOT EXISTS resolution VARCHAR(10);
  ALTER TABLE rockport_video_jobs ALTER COLUMN invocation_arn DROP NOT NULL;
  ALTER TABLE rockport_video_jobs ALTER COLUMN status SET DEFAULT 'pending';
"
echo "Video jobs table ready."

# Sidecar env file — append video-specific vars to LiteLLM env
(
  umask 077
  cat >> /etc/litellm/env <<VIDENVEOF
VIDEO_BUCKET=${video_bucket_name}
VIDEO_BUCKET_US_WEST_2=${video_bucket_us_west_2}
VIDEO_MAX_CONCURRENT_JOBS=${video_max_concurrent_jobs}
VIDENVEOF
)

# Systemd unit for video sidecar
cp /tmp/rockport-artifact/config/rockport-video.service /etc/systemd/system/rockport-video.service

# --- Cloudflared ---
echo "Installing cloudflared..."
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64" \
  -o /tmp/cloudflared-linux-amd64

# Verify SHA256 checksum against pinned hash (cloudflared releases don't include per-file checksum files)
ACTUAL_SHA256=$(sha256sum /tmp/cloudflared-linux-amd64 | awk '{print $1}')
if [[ "$ACTUAL_SHA256" == "$CLOUDFLARED_SHA256" ]]; then
  echo "cloudflared $CLOUDFLARED_VERSION checksum verified."
else
  echo "FATAL: cloudflared SHA256 checksum verification failed"
  echo "  Expected: $CLOUDFLARED_SHA256"
  echo "  Actual:   $ACTUAL_SHA256"
  exit 1
fi

chmod +x /tmp/cloudflared-linux-amd64
mv /tmp/cloudflared-linux-amd64 /usr/local/bin/cloudflared
rm -f /tmp/cloudflared-linux-amd64.sha256sum
echo "cloudflared installed."

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
cp /tmp/rockport-artifact/config/cloudflared.service /etc/systemd/system/cloudflared.service

# Cleanup artifact
rm -rf /tmp/rockport-artifact /tmp/rockport-artifact.tar.gz

# --- Start services ---
echo "Starting services..."
systemctl daemon-reload
systemctl enable litellm cloudflared rockport-video
systemctl start litellm
systemctl start cloudflared
systemctl start --no-block rockport-video

echo "=== Rockport bootstrap completed at $(date) ==="
