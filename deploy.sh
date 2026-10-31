#!/usr/bin/env bash
# Deploy the TradingView -> MT5 portal on an Ubuntu 24.04 VPS.
# Run as root (or with sudo) from the folder containing app.py.
#
# Usage:
#   DOMAIN=sparkrelai.ecovoyage.net ./deploy.sh
#   # then, after DNS points at this VPS:
#   certbot --nginx -d sparkrelai.ecovoyage.net
#
# What it does:
#   - installs python3, nginx, ufw
#   - copies the portal to /opt/sparkrelai
#   - installs a systemd service (portal on 127.0.0.1:8000 only)
#   - installs an nginx reverse proxy for $DOMAIN
#   - opens only SSH (22), HTTP (80) and HTTPS (443)
# It does NOT create a database, users, or TLS certificate by itself.
# Certbot is a separate step, after DNS has propagated.
set -euo pipefail

DOMAIN="${DOMAIN:-sparkrelai.ecovoyage.net}"
APP_DIR="/opt/sparkrelai"
PORT="${PORT:-8000}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root, or with sudo." >&2
  exit 1
fi

echo "== Installing packages =="
apt-get update
apt-get install -y python3 nginx ufw certbot python3-certbot-nginx

echo "== Installing portal to $APP_DIR =="
mkdir -p "$APP_DIR"
cp app.py TradingViewBridge.mq5 README.md DEPLOY.md "$APP_DIR/" 2>/dev/null || true
cp deploy/nginx-sparkrelai.conf "/etc/nginx/sites-available/sparkrelai" 2>/dev/null || true
# If the nginx template was not copied from deploy/, write it from DOMAIN.
if ! grep -q "$DOMAIN" /etc/nginx/sites-available/sparkrelai 2>/dev/null; then
  sed "s/DOMAIN_PLACEHOLDER/$DOMAIN/g; s/PORT_PLACEHOLDER/$PORT/g" \
    deploy/nginx-sparkrelai.conf > /etc/nginx/sites-available/sparkrelai
fi
ln -sf /etc/nginx/sites-available/sparkrelai /etc/nginx/sites-enabled/sparkrelai
rm -f /etc/nginx/sites-enabled/default

echo "== Installing systemd service =="
sed "s|PORT_PLACEHOLDER|$PORT|g" deploy/sparkrelai.service > /etc/systemd/system/sparkrelai.service
systemctl daemon-reload
systemctl enable sparkrelai
systemctl restart sparkrelai

echo "== Firewall =="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true

echo "== Nginx =="
nginx -t
systemctl enable nginx
systemctl restart nginx

echo ""
echo "Done. Next steps:"
echo "  1. Make sure Route53: sparkrelai.ecovoyage.net (A) -> this VPS public IP"
echo "  2. Wait for DNS, then run: certbot --nginx -d $DOMAIN"
echo "  3. Check: curl -f https://$DOMAIN/healthz"
echo "  4. Open https://$DOMAIN in a browser and sign up (first account = admin)"
echo "  5. Back up $APP_DIR/portal.db regularly"
