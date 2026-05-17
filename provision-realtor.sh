#!/bin/bash
# provision-realtor.sh — Spin up a new Realtor Assistant agent from scratch.
#
# Usage:
#   ./provision-realtor.sh "Jane Doe" "jane@cbdfw.com" "@jane_realtor"
#
# What it does:
#   1. Creates a Lightsail instance (Ubuntu 22.04, 4GB RAM)
#   2. Bootstraps OS via cloud-init
#   3. Clones the realtor-agent-template repo
#   4. Injects realtor-specific config
#   5. Sets up PostgreSQL schema
#   6. Installs Libretto + Playwright
#   7. Deploys Libretto Cloud workflows
#   8. Starts Hermes Agent via PM2
#   9. Prints onboarding instructions
#
# Prerequisites:
#   - AWS CLI installed and configured (profile: default or AWS_PROFILE)
#   - GitHub repo cloned: tacshooter/realtor-agent-template
#   - Libretto Cloud account set up
#
# Time to working agent: ~5 minutes

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AVAILABILITY_ZONE="${AZ:-us-east-2a}"
LIGHTSAIL_BUNDLE="${BUNDLE:-medium_2_0}"  # 4GB RAM, 2 vCPU, 80GB SSD — $20/mo
LIGHTSAIL_BLUEPRINT="${BLUEPRINT:-ubuntu_22_04}"
SSH_KEY_NAME="${SSH_KEY_NAME:-realtor-agent-key}"
TEMPLATE_REPO="${TEMPLATE_REPO:-git@github.com:tacshooter/realtor-agent-template.git}"

# ── Input Validation ───────────────────────────────────────────
REALTOR_NAME="${1:-}"
REALTOR_EMAIL="${2:-}"
TELEGRAM_USERNAME="${3:-}"

if [[ -z "$REALTOR_NAME" || -z "$REALTOR_EMAIL" || -z "$TELEGRAM_USERNAME" ]]; then
    echo "Usage: $0 \"Full Name\" \"email@example.com\" \"@telegram_username\""
    echo ""
    echo "Example:"
    echo "  $0 \"Jane Doe\" \"jane@cbdfw.com\" \"@jane_realtor\""
    exit 1
fi

# Generate a clean slug from the name
SLUG=$(echo "$REALTOR_NAME" | tr '[:upper:] ' '[:lower:]' | tr -cd '[:alnum:]-')
INSTANCE_NAME="realtor-${SLUG}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Realtor Assistant — Provisioning"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Name:      ${REALTOR_NAME}"
echo "  Email:     ${REALTOR_EMAIL}"
echo "  Telegram:  ${TELEGRAM_USERNAME}"
echo "  Instance:  ${INSTANCE_NAME}"
echo "  Region:    ${AWS_REGION}"
echo "  Bundle:    ${LIGHTSAIL_BUNDLE}"
echo ""

# ── Step 1: Create Lightsail Instance ──────────────────────────
echo "[1/7] Creating Lightsail instance: ${INSTANCE_NAME}..."

aws lightsail create-instances \
    --profile "$AWS_PROFILE" \
    --instance-names "$INSTANCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --blueprint-id "$LIGHTSAIL_BLUEPRINT" \
    --bundle-id "$LIGHTSAIL_BUNDLE" \
    --user-data "file://cloud-init/realtor-bootstrap.sh" \
    --output text > /dev/null

echo "       Instance creation initiated. Waiting for it to be running..."

# Wait for instance to be running (max 5 minutes)
for i in $(seq 1 60); do
    STATE=$(aws lightsail get-instance \
        --profile "$AWS_PROFILE" \
        --instance-name "$INSTANCE_NAME" \
        --query 'instance.state.name' \
        --output text 2>/dev/null || echo "pending")

    if [[ "$STATE" == "running" ]]; then
        break
    fi
    echo "       State: ${STATE} (${i}/60)..."
    sleep 5
done

if [[ "$STATE" != "running" ]]; then
    echo "ERROR: Instance did not reach 'running' state within 5 minutes."
    exit 1
fi

# Get public IP
IP=$(aws lightsail get-instance \
    --profile "$AWS_PROFILE" \
    --instance-name "$INSTANCE_NAME" \
    --query 'instance.publicIpAddress' \
    --output text)

echo "       ✅ Instance running at ${IP}"

# ── Step 2: Open Network Ports ─────────────────────────────────
echo "[2/7] Configuring firewall..."

aws lightsail open-instance-public-ports \
    --profile "$AWS_PROFILE" \
    --instance-name "$INSTANCE_NAME" \
    --port-info \
        fromPort=443,toPort=443,protocol=TCP \
        fromPort=80,toPort=80,protocol=TCP \
    --output text > /dev/null

echo "       ✅ Ports 80, 443 open"

# ── Step 3: Wait for cloud-init to finish ─────────────────────
echo "[3/7] Waiting for cloud-init bootstrap to complete..."

sleep 10  # Give SSH a moment to come up

for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "admin@${IP}" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; then
        echo "       ✅ Cloud-init complete"
        break
    fi
    echo "       Waiting for cloud-init (${i}/30)..."
    sleep 10
done

# ── Step 4: Clone Template & Inject Config ────────────────────
echo "[4/7] Cloning template and injecting configuration..."

ssh -o StrictHostKeyChecking=no "admin@${IP}" "bash -s" << ENDSSH
set -euo pipefail

# Clone the template repo
cd /opt
git clone ${TEMPLATE_REPO} realtor-agent
cd /opt/realtor-agent

# Inject realtor-specific values
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{REALTOR_NAME}}/${REALTOR_NAME}/g" {} +
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{REALTOR_EMAIL}}/${REALTOR_EMAIL}/g" {} +
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{TELEGRAM_USERNAME}}/${TELEGRAM_USERNAME}/g" {} +

# Install Libretto + Playwright
npm install
npx libretto setup --skip-browsers  # Chromium already installed by cloud-init

# Set ownership
chown -R realtor:realtor /opt/realtor-agent

echo "✅ Template cloned and configured"
ENDSSH

# ── Step 5: Initialize PostgreSQL ─────────────────────────────
echo "[5/7] Setting up PostgreSQL..."

ssh -o StrictHostKeyChecking=no "admin@${IP}" "bash -s" << 'ENDSSH'
set -euo pipefail

# Run schema
sudo -u postgres psql -d realtor_agent -f /opt/realtor-agent/db/schema.sql

# Generate encryption key for credentials
ENCRYPTION_KEY=$(openssl rand -hex 32)
sudo -u postgres psql -d realtor_agent << SQL
-- Store encryption key in a secure table (only accessible by realtor user)
CREATE TABLE IF NOT EXISTS config (
    key   VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO config (key, value) VALUES ('encryption_key', '${ENCRYPTION_KEY}')
ON CONFLICT (key) DO UPDATE SET value = '${ENCRYPTION_KEY}';
SQL

echo "✅ PostgreSQL schema initialized"
ENDSSH

# ── Step 6: Start Hermes Agent ────────────────────────────────
echo "[6/7] Starting Hermes Agent..."

ssh -o StrictHostKeyChecking=no "admin@${IP}" "bash -s" << 'ENDSSH'
set -euo pipefail

# Copy Hermes config to expected location
mkdir -p /home/realtor/.hermes
cp /opt/realtor-agent/hermes/config.yaml /home/realtor/.hermes/config.yaml
chown -R realtor:realtor /home/realtor/.hermes

# Start Hermes via PM2 as the realtor user
sudo -u realtor pm2 start hermes --name "realtor-agent" --cwd /opt/realtor-agent
sudo -u realtor pm2 save
sudo pm2 startup systemd -u realtor --hp /home/realtor

echo "✅ Hermes Agent started"
ENDSSH

# ── Step 7: Onboarding Instructions ───────────────────────────
echo "[7/7] ✅ Provisioning complete!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Agent Ready: ${REALTOR_NAME}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Instance:  ${INSTANCE_NAME}"
echo "  IP:        ${IP}"
echo "  SSH:       ssh admin@${IP}"
echo ""
echo "  📱 Next: Connect Telegram bot to this instance"
echo "     (If using a shared bot, configure the webhook to ${IP})"
echo ""
echo "  🏠 The agent will text ${REALTOR_NAME} automatically"
echo "     to begin onboarding (MLS URL, credentials, preferences)."
echo ""
echo "  📊 Estimated monthly cost: \$40 (\$20 Lightsail + \$20 Libretto Cloud)"
echo ""
echo "  To tear down:"
echo "    aws lightsail delete-instance --instance-name ${INSTANCE_NAME}"
echo ""
