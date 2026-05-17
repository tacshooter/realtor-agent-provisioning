#!/bin/bash
# cloud-init/realtor-bootstrap.sh
# Runs on Lightsail instance first boot (Ubuntu 22.04).
# Handles OS-level setup before SSH is available.

set -euo pipefail

echo "[cloud-init] Starting Realtor Agent bootstrap..."

# 1. System updates
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl git build-essential \
    postgresql postgresql-contrib \
    nginx certbot python3-certbot-nginx \
    chromium-browser xvfb \
    ufw unattended-upgrades

# 2. Install Node.js 20.x
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 3. Install PM2 globally
npm install -g pm2

# 4. Install Libretto CLI
curl -fsSL https://libretto.sh/install.sh | bash

# 5. Create realtor user
useradd --create-home --shell /bin/bash realtor
mkdir -p /opt/realtor-agent
chown -R realtor:realtor /opt/realtor-agent

# 6. Firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 7. Configure unattended-upgrades for security patches
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

# 8. Configure PostgreSQL
sudo -u postgres psql << 'SQL'
CREATE USER realtor WITH PASSWORD 'CHANGE_ME_ON_PROVISION';
CREATE DATABASE realtor_agent OWNER realtor;
GRANT ALL PRIVILEGES ON DATABASE realtor_agent TO realtor;
SQL

# 9. Enable PostgreSQL on boot
systemctl enable postgresql
systemctl start postgresql

# 10. Placeholder for Hermes Agent install
# The provision-realtor.sh script handles this via SSH after instance is ready.
mkdir -p /opt/realtor-agent/hermes
mkdir -p /opt/realtor-agent/skills
mkdir -p /opt/realtor-agent/context
mkdir -p /opt/realtor-agent/libretto/workflows
mkdir -p /opt/realtor-agent/db

echo "[cloud-init] Bootstrap complete. Instance ready for application provisioning."
