#!/bin/bash
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
echo "Creating swap..."
dd if=/dev/zero of=/swapfile bs=1M count=512
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile swap swap defaults 0 0" >> /etc/fstab

# --- PostgreSQL 15 ---
echo "Installing PostgreSQL 15..."
dnf install -y postgresql15-server postgresql15

/usr/bin/postgresql-setup --initdb

# Apply tuning config
cat > /var/lib/pgsql/data/postgresql-tuning.conf <<'PGCONF'
shared_buffers = 64MB
work_mem = 4MB
effective_cache_size = 256MB
maintenance_work_mem = 32MB
PGCONF

echo "include = 'postgresql-tuning.conf'" >> /var/lib/pgsql/data/postgresql.conf

# Keep peer auth for postgres superuser, use md5 for litellm_user (local + TCP)
sed -i '/^local\s\+all\s\+all\s\+peer/i local all litellm_user md5' /var/lib/pgsql/data/pg_hba.conf
sed -i '/^host\s\+all\s\+all\s\+127.0.0.1/i host all litellm_user 127.0.0.1/32 md5' /var/lib/pgsql/data/pg_hba.conf

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

# Create litellm database and user
DB_PASSWORD=$(openssl rand -hex 16)
sudo -u postgres psql -c "CREATE USER litellm_user WITH PASSWORD '$DB_PASSWORD'"
sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm_user;"
sudo -u postgres psql -d litellm -c "GRANT ALL ON SCHEMA public TO litellm_user;"

DATABASE_URL="postgresql://litellm_user:$DB_PASSWORD@localhost:5432/litellm"

# --- Fetch secrets from SSM ---
echo "Fetching secrets from SSM..."
MASTER_KEY=$(aws ssm get-parameter \
  --name "$MASTER_KEY_SSM_PATH" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

TUNNEL_TOKEN=$(aws ssm get-parameter \
  --name "$TUNNEL_TOKEN_SSM_PATH" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

# --- LiteLLM ---
echo "Installing LiteLLM..."
dnf install -y python3.11 python3.11-pip libatomic
pip3.11 install "litellm[proxy]==$LITELLM_VERSION" prisma

# Create litellm user with home directory (needed for prisma cache)
useradd --system --create-home --shell /usr/sbin/nologin litellm

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

# Env file
cat > /etc/litellm/env <<EOF
DATABASE_URL=$DATABASE_URL
LITELLM_MASTER_KEY=$MASTER_KEY
EOF
chmod 600 /etc/litellm/env
chown litellm:litellm /etc/litellm/env

# Systemd unit
cat > /etc/systemd/system/litellm.service <<'LITELLMSVC'
${litellm_service}
LITELLMSVC

# --- Cloudflared ---
echo "Installing cloudflared..."
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64" \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Create cloudflared user
useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared

# Env file
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/env <<EOF
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF
chmod 600 /etc/cloudflared/env
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
