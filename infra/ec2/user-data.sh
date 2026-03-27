#!/bin/bash
# EC2 instance boot script. Runs as root via user-data.

set -euo pipefail
exec > /var/log/user-data.log 2>&1
echo "=== Prismata 3D Gen — Instance Boot $(date) ==="

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"

# Get instance ID
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/instance-id")
echo "Instance ID: $INSTANCE_ID"

# Get Discord webhook URL from SSM
export DISCORD_WEBHOOK_URL=$(aws ssm get-parameter \
    --name /prismata-3d/discord-webhook-url \
    --region "$REGION" --with-decryption \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

# 1. Install cloudflared
echo "--- Installing cloudflared ---"
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb

# 2. Start quick tunnel (random *.trycloudflare.com URL)
echo "--- Starting quick tunnel ---"
mkdir -p /opt/prismata-3d/output

# Start tunnel in background, capture the URL from its output
cloudflared tunnel --url http://localhost:8188 --no-autoupdate > /tmp/tunnel.log 2>&1 &
TUNNEL_PID=$!

# Wait for the URL to appear in the log (up to 30 seconds)
TUNNEL_URL=""
for i in $(seq 1 30); do
    sleep 1
    TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
done

if [ -n "$TUNNEL_URL" ]; then
    echo "Tunnel URL: $TUNNEL_URL"
    # Write to SSM so the Discord bot can read it
    aws ssm put-parameter \
        --name "/prismata-3d/tunnel-url/$INSTANCE_ID" \
        --type String \
        --value "$TUNNEL_URL" \
        --overwrite \
        --region "$REGION" || echo "Failed to write tunnel URL to SSM"
else
    echo "WARNING: Tunnel URL not captured after 30s"
fi

# 3. Start idle watchdog
echo "--- Starting idle watchdog ---"
cat > /etc/systemd/system/idle-watchdog.service <<EOF
[Unit]
Description=Prismata 3D Gen Idle Watchdog
After=network.target
[Service]
Type=simple
ExecStart=/opt/prismata-3d/idle-watchdog.sh
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

# Copy scripts (these would be baked into the AMI in production)
# For now they're embedded or fetched from S3
aws s3 cp "s3://prismata-3d-models/scripts/idle-watchdog.sh" /opt/prismata-3d/idle-watchdog.sh --region "$REGION" 2>/dev/null || \
    echo '#!/bin/bash\necho "watchdog placeholder"' > /opt/prismata-3d/idle-watchdog.sh
chmod +x /opt/prismata-3d/idle-watchdog.sh

systemctl daemon-reload
systemctl enable idle-watchdog
systemctl start idle-watchdog

# 4. Start spot monitor
echo "--- Starting spot monitor ---"
cat > /etc/systemd/system/spot-monitor.service <<EOF
[Unit]
Description=Prismata 3D Gen Spot Monitor
After=network.target
[Service]
Type=simple
ExecStart=/opt/prismata-3d/spot-monitor.sh
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

aws s3 cp "s3://prismata-3d-models/scripts/spot-monitor.sh" /opt/prismata-3d/spot-monitor.sh --region "$REGION" 2>/dev/null || \
    echo '#!/bin/bash\necho "spot-monitor placeholder"' > /opt/prismata-3d/spot-monitor.sh
chmod +x /opt/prismata-3d/spot-monitor.sh

systemctl daemon-reload
systemctl enable spot-monitor
systemctl start spot-monitor

# 5. Start placeholder web server on port 8188
echo "--- Starting placeholder web server ---"
echo "<h1>Prismata 3D Gen</h1><p>Instance: $INSTANCE_ID</p><p>Phase 1B: ComfyUI will replace this.</p>" > /opt/prismata-3d/output/index.html
python3 -m http.server 8188 --directory /opt/prismata-3d/output &

echo "=== Boot complete $(date) ==="
