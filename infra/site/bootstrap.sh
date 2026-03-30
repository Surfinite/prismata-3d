#!/bin/bash
# infra/site/bootstrap.sh
# Bootstrap the Fabrication Terminal on a fresh site box instance.
# Called from user-data on spot recovery. Idempotent — safe to re-run.
#
# Prerequisites on the AMI:
#   - Node.js 18+ installed
#   - nginx installed
#   - certbot installed
#   - AWS CLI configured (instance role)

set -euo pipefail

S3_BUCKET="prismata-3d-models"
REGION="us-east-1"
INSTALL_DIR="/opt/fabricate"
DOMAIN="fabricate.prismata.live"

echo "=== Fabricate Bootstrap ==="

# 1. Pull server bundle from S3
echo "--- Pulling server bundle from S3 ---"
aws s3 sync "s3://${S3_BUCKET}/deploy/fabricate/" "$INSTALL_DIR/" \
    --region "$REGION" --exclude "*.db" --exclude "*.db-*" --exclude "node_modules/*" --quiet

# 2. Pull frontend from S3
echo "--- Pulling frontend ---"
mkdir -p "$INSTALL_DIR/public"
aws s3 cp "s3://${S3_BUCKET}/frontend/index.html" "$INSTALL_DIR/public/index.html" \
    --region "$REGION" --quiet

# 3. Pull manifest and descriptions
echo "--- Pulling assets ---"
aws s3 cp "s3://${S3_BUCKET}/asset-prep/manifest.json" "$INSTALL_DIR/public/manifest.json" \
    --region "$REGION" --quiet || true
aws s3 cp "s3://${S3_BUCKET}/asset-prep/descriptions.json" "$INSTALL_DIR/public/descriptions.json" \
    --region "$REGION" --quiet || true

# 4. Install npm dependencies (if node_modules missing)
if [ ! -d "$INSTALL_DIR/node_modules" ]; then
    echo "--- Installing dependencies ---"
    cd "$INSTALL_DIR" && npm install --production 2>&1
fi

# 5. Set ownership
chown -R ubuntu:ubuntu "$INSTALL_DIR"

# 6. Install systemd service
cat > /etc/systemd/system/fabricate.service <<'SVCEOF'
[Unit]
Description=Fabrication Terminal API Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/fabricate
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable fabricate
systemctl restart fabricate

# 7. Install nginx vhost + SSL cert
if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
    echo "--- Setting up nginx + SSL ---"
    cat > "/etc/nginx/sites-available/$DOMAIN" <<'NGXEOF'
server {
    listen 80;
    server_name fabricate.prismata.live;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGXEOF
    ln -sf "/etc/nginx/sites-available/$DOMAIN" /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx

    # Get SSL cert (certbot adds the HTTPS block automatically)
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email surfinite@gmail.com || true
fi

# 8. Verify
sleep 2
if systemctl is-active --quiet fabricate; then
    echo "=== Fabricate bootstrap complete ==="
else
    echo "=== WARNING: fabricate service failed to start ==="
    journalctl -u fabricate --no-pager -n 10
fi
