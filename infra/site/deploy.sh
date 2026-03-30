#!/bin/bash
# infra/site/deploy.sh
# Deploy the Fabrication Terminal to the site box.
# Run from local machine. Requires SSH access to the site box.
set -euo pipefail

SITE_BOX="ubuntu@<SITE_BOX_EIP>"
SSH_KEY="$HOME/.ssh/<SSH_KEY>.pem"
SSH="ssh -i $SSH_KEY $SITE_BOX"
SCP="scp -i $SSH_KEY"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND_DIR="$(cd "$SCRIPT_DIR/../frontend" && pwd)"

echo "=== Deploying Fabrication Terminal ==="

# 1. Create directory structure on site box
echo "--- Setting up directories ---"
$SSH "sudo mkdir -p /opt/fabricate/public /opt/fabricate/routes /opt/fabricate/lib"

# 2. Upload server files
echo "--- Uploading server files ---"
$SCP "$SCRIPT_DIR/package.json" "$SITE_BOX:/tmp/fabricate-package.json"
$SCP "$SCRIPT_DIR/server.js" "$SITE_BOX:/tmp/fabricate-server.js"
$SCP "$SCRIPT_DIR/routes/s3.js" "$SITE_BOX:/tmp/fabricate-s3.js"
$SCP "$SCRIPT_DIR/routes/status.js" "$SITE_BOX:/tmp/fabricate-status.js"
$SCP "$SCRIPT_DIR/routes/access.js" "$SITE_BOX:/tmp/fabricate-access.js"
$SCP "$SCRIPT_DIR/routes/gpu.js" "$SITE_BOX:/tmp/fabricate-gpu.js"
$SCP "$SCRIPT_DIR/routes/admin.js" "$SITE_BOX:/tmp/fabricate-admin.js"
$SCP "$SCRIPT_DIR/lib/s3client.js" "$SITE_BOX:/tmp/fabricate-s3client.js"
$SCP "$SCRIPT_DIR/lib/db.js" "$SITE_BOX:/tmp/fabricate-db.js"
$SCP "$SCRIPT_DIR/lib/reconciler.js" "$SITE_BOX:/tmp/fabricate-reconciler.js"
$SCP "$SCRIPT_DIR/lib/discord.js" "$SITE_BOX:/tmp/fabricate-discord.js"

# 3. Upload frontend
echo "--- Uploading frontend ---"
$SCP "$FRONTEND_DIR/index.html" "$SITE_BOX:/tmp/fabricate-index.html"

# 4. Upload infrastructure files
echo "--- Uploading service + nginx config ---"
$SCP "$SCRIPT_DIR/fabricate.service" "$SITE_BOX:/tmp/fabricate.service"
$SCP "$SCRIPT_DIR/fabricate.nginx.conf" "$SITE_BOX:/tmp/fabricate.nginx.conf"

# 5. Download static assets from S3 locally, then upload to site box
echo "--- Downloading assets from S3 (locally) ---"
aws s3 cp s3://prismata-3d-models/asset-prep/manifest.json /tmp/fabricate-manifest.json --region us-east-1
aws s3 cp s3://prismata-3d-models/asset-prep/descriptions.json /tmp/fabricate-descriptions.json --region us-east-1
$SCP /tmp/fabricate-manifest.json "$SITE_BOX:/tmp/fabricate-manifest.json"
$SCP /tmp/fabricate-descriptions.json "$SITE_BOX:/tmp/fabricate-descriptions.json"

# 6. Fetch admin key from SSM and write env file on the server
echo "--- Configuring admin key ---"
ADMIN_KEY=$(aws ssm get-parameter --name /prismata-3d/admin-key --region us-east-1 --with-decryption --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [ -n "$ADMIN_KEY" ]; then
  $SSH "echo 'ADMIN_KEY=$ADMIN_KEY' | sudo tee /opt/fabricate/.env > /dev/null && sudo chmod 600 /opt/fabricate/.env && sudo chown ubuntu:ubuntu /opt/fabricate/.env"
else
  echo "WARNING: No admin key found in SSM — admin endpoints will be disabled"
fi

# 7. Move files into place
echo "--- Installing files ---"
$SSH "sudo cp /tmp/fabricate-package.json /opt/fabricate/package.json && \
      sudo cp /tmp/fabricate-server.js /opt/fabricate/server.js && \
      sudo cp /tmp/fabricate-s3.js /opt/fabricate/routes/s3.js && \
      sudo cp /tmp/fabricate-status.js /opt/fabricate/routes/status.js && \
      sudo cp /tmp/fabricate-access.js /opt/fabricate/routes/access.js && \
      sudo cp /tmp/fabricate-gpu.js /opt/fabricate/routes/gpu.js && \
      sudo cp /tmp/fabricate-admin.js /opt/fabricate/routes/admin.js && \
      sudo cp /tmp/fabricate-s3client.js /opt/fabricate/lib/s3client.js && \
      sudo cp /tmp/fabricate-db.js /opt/fabricate/lib/db.js && \
      sudo cp /tmp/fabricate-reconciler.js /opt/fabricate/lib/reconciler.js && \
      sudo cp /tmp/fabricate-discord.js /opt/fabricate/lib/discord.js && \
      sudo cp /tmp/fabricate-index.html /opt/fabricate/public/index.html && \
      sudo cp /tmp/fabricate-manifest.json /opt/fabricate/public/manifest.json && \
      sudo cp /tmp/fabricate-descriptions.json /opt/fabricate/public/descriptions.json && \
      sudo chown -R ubuntu:ubuntu /opt/fabricate"

# 8. Install npm dependencies
echo "--- Installing dependencies ---"
$SSH "cd /opt/fabricate && npm install --omit=dev"

# 9. Install systemd service
echo "--- Installing service ---"
$SSH "sudo cp /tmp/fabricate.service /etc/systemd/system/fabricate.service && \
      sudo systemctl daemon-reload && \
      sudo systemctl enable fabricate && \
      sudo systemctl restart fabricate"

# 10. Check service is running
echo "--- Verifying service ---"
sleep 2
if ! $SSH "sudo systemctl is-active fabricate && curl -sf http://127.0.0.1:3100/healthz"; then
    echo "ERROR: Service failed to start. Recent logs:"
    $SSH "sudo journalctl -u fabricate -n 50 --no-pager"
    exit 1
fi

# 11. Sync server bundle to S3 for spot recovery bootstrap
echo "--- Syncing server bundle to S3 ---"
aws s3 sync "$SCRIPT_DIR/" s3://prismata-3d-models/deploy/fabricate/ \
    --region us-east-1 --exclude "*.sh" --exclude "*.conf" --exclude "*.service" \
    --exclude "*.md" --exclude "node_modules/*" --quiet
aws s3 cp "$SCRIPT_DIR/bootstrap.sh" s3://prismata-3d-models/deploy/fabricate/bootstrap.sh \
    --region us-east-1 --quiet
aws s3 cp "$FRONTEND_DIR/index.html" s3://prismata-3d-models/frontend/index.html \
    --region us-east-1 --quiet

echo ""
echo "=== Fabricate server deployed ==="
echo "Service: sudo systemctl status fabricate"
echo "Logs: sudo journalctl -u fabricate -f"
