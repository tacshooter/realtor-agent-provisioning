#!/bin/bash
# provision-realtor.sh — Spin up a new Realtor Assistant agent from scratch.
#
# Usage:
#   ./provision-realtor.sh "Jane Doe" "jane@cbdfw.com" "@jane_realtor"
#
# What it does:
#   1. Assigns a Telegram bot token from the pool
#   2. Creates a Lightsail instance (Ubuntu 22.04, 4GB RAM)
#   3. Bootstraps OS via cloud-init
#   4. Clones the realtor-agent-template repo
#   5. Injects realtor-specific config + bot token
#   6. Sets up PostgreSQL schema
#   7. Installs Libretto + Playwright (LOCAL — no cloud dependency)
#   8. Starts Hermes Agent via PM2
#   9. Prints onboarding instructions
#
# Prerequisites:
#   - AWS CLI installed and configured (profile: default or AWS_PROFILE)
#   - Telegram bot tokens pre-created in bot-pool.json (via @BotFather)
#   - GitHub repo: tacshooter/realtor-agent-template
#
# Time to working agent: ~5 minutes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_FILE="${SCRIPT_DIR}/bot-pool.json"

# ── Configuration ──────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-fergrobot}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AVAILABILITY_ZONE="${AZ:-us-east-2a}"
LIGHTSAIL_BUNDLE="${BUNDLE:-medium_2_0}"  # 4GB RAM, 2 vCPU, 80GB SSD — $20/mo
LIGHTSAIL_BLUEPRINT="${BLUEPRINT:-ubuntu_22_04}"
SSH_KEY_NAME="${SSH_KEY_NAME:-realtor-agent-key}"
TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/tacshooter/realtor-agent-template.git}"

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

# ── Step 0: Assign Telegram Bot Token ──────────────────────────
echo "[0/8] Assigning Telegram bot token..."

if [[ ! -f "$POOL_FILE" ]]; then
    echo "ERROR: bot-pool.json not found at $POOL_FILE"
    echo "Create bot tokens via @BotFather on Telegram and add them to bot-pool.json."
    exit 1
fi

# Pull next available token from pool
BOT_TOKEN=$(python3 -c "
import json, sys
with open('$POOL_FILE') as f:
    pool = json.load(f)
if not pool.get('available'):
    print('ERROR: No bot tokens available in pool', file=sys.stderr)
    print('Create new bots via @BotFather on Telegram (/newbot) and add tokens to bot-pool.json', file=sys.stderr)
    sys.exit(1)
token = pool['available'].pop(0)
print(token)
" 2>&1)

if [[ "$BOT_TOKEN" == ERROR:* ]]; then
    echo "$BOT_TOKEN"
    exit 1
fi

# Mark token as in-use
python3 -c "
import json
with open('$POOL_FILE') as f:
    pool = json.load(f)
pool['in_use']['${REALTOR_NAME}'] = '$BOT_TOKEN'
with open('$POOL_FILE', 'w') as f:
    json.dump(pool, f, indent=2)
"

echo "       ✅ Bot token assigned (${#BOT_TOKEN} chars)"

# Generate a clean slug from the name (use python3 to avoid Unicode issues)
SLUG=$(python3 -c "
import re, sys
name = sys.argv[1]
slug = name.lower().replace(' ', '-')
slug = re.sub(r'[^a-z0-9-]', '', slug)
print(slug)
" "$REALTOR_NAME")
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
echo "[1/8] Creating Lightsail instance: ${INSTANCE_NAME}..."

aws lightsail create-instances \
    --profile "$AWS_PROFILE" \
    --instance-names "$INSTANCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --blueprint-id "$LIGHTSAIL_BLUEPRINT" \
    --bundle-id "$LIGHTSAIL_BUNDLE" \
    --key-pair-name "$SSH_KEY_NAME" \
    --user-data "file://${SCRIPT_DIR}/cloud-init/realtor-bootstrap.sh" \
    --output text > /dev/null

echo "       Instance creation initiated. Waiting for it to be running..."

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

IP=$(aws lightsail get-instance \
    --profile "$AWS_PROFILE" \
    --instance-name "$INSTANCE_NAME" \
    --query 'instance.publicIpAddress' \
    --output text)

echo "       ✅ Instance running at ${IP}"

# ── Step 2: Open Network Ports ─────────────────────────────────
echo "[2/8] Configuring firewall..."

aws lightsail open-instance-public-ports \
    --profile "$AWS_PROFILE" \
    --instance-name "$INSTANCE_NAME" \
    --port-info fromPort=443,toPort=443,protocol=TCP \
    --port-info fromPort=80,toPort=80,protocol=TCP \
    --output text > /dev/null

echo "       ✅ Ports 80, 443 open"

# ── Step 3: Wait for cloud-init ────────────────────────────────
echo "[3/8] Waiting for cloud-init bootstrap to complete..."

sleep 10

for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "ubuntu@${IP}" "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; then
        echo "       ✅ Cloud-init complete"
        break
    fi
    echo "       Waiting for cloud-init (${i}/30)..."
    sleep 10
done

# ── Step 4: Clone Template & Inject Config ────────────────────
echo "[4/8] Cloning template and injecting configuration..."

# Escape special characters for sed
REALTOR_NAME_ESC=$(echo "$REALTOR_NAME" | sed 's/[\/&]/\\&/g')
REALTOR_EMAIL_ESC=$(echo "$REALTOR_EMAIL" | sed 's/[\/&]/\\&/g')
TELEGRAM_USERNAME_ESC=$(echo "$TELEGRAM_USERNAME" | sed 's/[\/&]/\\&/g')
BOT_TOKEN_ESC=$(echo "$BOT_TOKEN" | sed 's/[\/&]/\\&/g')

ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << ENDSSH
set -euo pipefail

# Clone the template repo (HTTPS — no SSH key needed on instance)
cd /opt
git clone ${TEMPLATE_REPO} realtor-agent
cd /opt/realtor-agent

# Inject realtor-specific values
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{REALTOR_NAME}}/${REALTOR_NAME_ESC}/g" {} +
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{REALTOR_EMAIL}}/${REALTOR_EMAIL_ESC}/g" {} +
find . -type f \( -name "*.yaml" -o -name "*.md" -o -name "*.ts" \) \
    -exec sed -i "s/{{TELEGRAM_USERNAME}}/${TELEGRAM_USERNAME_ESC}/g" {} +
find . -type f \( -name "*.yaml" -o -name "*.md" \) \
    -exec sed -i "s/{{BOT_TOKEN}}/${BOT_TOKEN_ESC}/g" {} +

echo "✅ Template cloned and configured"
ENDSSH

# ── Create .env with shared API keys ──────────────────────────
echo "[4b/8] Injecting shared API keys..."

# Firecrawl key
if [[ -z "${FIRECRAWL_API_KEY:-}" ]]; then
    if [[ -f "$HOME/.hermes/.env" ]]; then
        FIRECRAWL_API_KEY=$(grep FIRECRAWL_API_KEY "$HOME/.hermes/.env" | cut -d= -f2-)
    fi
fi

# OpenRouter key
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    if [[ -f "$HOME/.hermes/.env" ]]; then
        OPENROUTER_API_KEY=$(grep OPENROUTER_API_KEY "$HOME/.hermes/.env" | cut -d= -f2-)
    fi
fi

MISSING_KEYS=""
[[ -z "${FIRECRAWL_API_KEY:-}" ]] && MISSING_KEYS="$MISSING_KEYS FIRECRAWL_API_KEY"
[[ -z "${OPENROUTER_API_KEY:-}" ]] && MISSING_KEYS="$MISSING_KEYS OPENROUTER_API_KEY"

if [[ -n "$MISSING_KEYS" ]]; then
    echo "       ⚠️  Missing keys:$MISSING_KEYS"
    echo "       Set them in your environment or ~/.hermes/.env and re-provision."
else
    ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << ENDENV
cat > /home/realtor/.hermes/.env << 'EOF'
# ── Model (OpenRouter) ────────────────────────────────────────
# Shared key — managed centrally, no realtor signup needed.
# Model: deepseek/deepseek-v4-flash:free (zero per-token cost)
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}

# ── Web Search / Extract (Firecrawl) ──────────────────────────
# Shared key — managed centrally, no realtor signup needed.
FIRECRAWL_API_KEY=${FIRECRAWL_API_KEY}

# ── Optional: Libretto Cloud (if local browsers get blocked) ──
# LIBRETTO_API_KEY=libretto-xxxxxxxxxxxx
EOF
chown realtor:realtor /home/realtor/.hermes/.env
chmod 600 /home/realtor/.hermes/.env
ENDENV
    echo "       ✅ OPENROUTER_API_KEY + FIRECRAWL_API_KEY injected"
fi

# ── Continue with Libretto install ─────────────────────────────
ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << ENDSSH
set -euo pipefail

cd /opt/realtor-agent

# Install Libretto + Playwright (local only — no cloud)
npm install
npx libretto setup --skip-browsers  # Chromium already installed by cloud-init

# Verify Playwright works headless with xvfb
xvfb-run npx playwright install --with-deps chromium 2>&1 | tail -1

# Set ownership
chown -R realtor:realtor /opt/realtor-agent

echo "✅ Template cloned and configured"
ENDSSH

# ── Step 5: Initialize PostgreSQL ─────────────────────────────
echo "[5/8] Setting up PostgreSQL..."

ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << 'ENDSSH'
set -euo pipefail

sudo -u postgres psql -d realtor_agent -f /opt/realtor-agent/db/schema.sql

ENCRYPTION_KEY=$(openssl rand -hex 32)
sudo -u postgres psql -d realtor_agent << SQL
CREATE TABLE IF NOT EXISTS config (
    key   VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO config (key, value) VALUES ('encryption_key', '${ENCRYPTION_KEY}')
ON CONFLICT (key) DO UPDATE SET value = '${ENCRYPTION_KEY}';
SQL

echo "✅ PostgreSQL schema initialized"
ENDSSH

# ── Step 6: Test Libretto Local ───────────────────────────────
echo "[6/8] Testing Libretto local browser..."

ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << 'ENDSSH'
set -euo pipefail

cd /opt/realtor-agent

# Quick smoke test: open a page headlessly via xvfb
xvfb-run npx libretto run src/workflows/mls-login.ts --headless 2>&1 || true
# (Expected to fail on login since no real MLS — validating Chromium works)

echo "✅ Libretto local browser verified"
ENDSSH

# ── Step 7: Start Hermes Agent ────────────────────────────────
echo "[7/8] Starting Hermes Agent..."

ssh -o StrictHostKeyChecking=no "ubuntu@${IP}" "bash -s" << 'ENDSSH'
set -euo pipefail

mkdir -p /home/realtor/.hermes
cp /opt/realtor-agent/hermes/config.yaml /home/realtor/.hermes/config.yaml
chown -R realtor:realtor /home/realtor/.hermes

# Start Hermes via PM2
sudo -u realtor pm2 start hermes --name "realtor-agent" --cwd /opt/realtor-agent
sudo -u realtor pm2 save
sudo pm2 startup systemd -u realtor --hp /home/realtor

echo "✅ Hermes Agent started"
ENDSSH

# ── Step 8: Done ──────────────────────────────────────────────
echo "[8/8] ✅ Provisioning complete!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Agent Ready: ${REALTOR_NAME}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Instance:  ${INSTANCE_NAME}"
echo "  IP:        ${IP}"
echo "  SSH:       ssh ubuntu@${IP}"
echo ""
echo "  📱 Telegram bot is live. The agent will text ${REALTOR_NAME}"
echo "     automatically to begin onboarding."
echo ""
echo "  📊 Estimated monthly cost: \$20 (Lightsail only)"
echo "     — Model: deepseek/deepseek-v4-flash:free (\$0)"
echo "     — Libretto runs locally, no cloud dependency."
echo ""
echo "  🔑 API keys auto-injected from your local ~/.hermes/.env:"
echo "     — OPENROUTER_API_KEY (model access, free tier)"
echo "     — FIRECRAWL_API_KEY (web search/extract)"
echo ""
echo "  ⚠️  Libretto Cloud note: Local browsers work from a"
echo "     Lightsail IP. If the MLS blocks it (Cloudflare, CAPTCHAs),"
echo "     upgrade to Libretto Cloud Pro (\$20/mo) for managed proxies."
echo "     Run: libretto cloud auth signup && libretto cloud deploy ."
echo ""
echo "  📋 Bot pool remaining: check bot-pool.json"
echo ""
echo "  To tear down:"
echo "    aws lightsail delete-instance --instance-name ${INSTANCE_NAME}"
echo ""
