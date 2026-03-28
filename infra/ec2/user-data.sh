#!/bin/bash
# EC2 instance boot script. Runs as root via user-data.
# ComfyUI, cloudflared, monitoring scripts, and systemd services are
# pre-installed in the AMI. This script just starts them and injects
# runtime config (webhook URL, tunnel URL).

set -euo pipefail
exec > /var/log/user-data.log 2>&1
echo "=== Prismata 3D Gen — Instance Boot $(date) ==="

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"

# Get instance ID
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/instance-id")
echo "Instance ID: $INSTANCE_ID"

# Get Discord webhook URL from SSM and inject into monitoring services
DISCORD_WEBHOOK_URL=$(aws ssm get-parameter \
    --name /prismata-3d/discord-webhook-url \
    --region "$REGION" --with-decryption \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

# Update the webhook URL in baked service files via drop-in overrides
mkdir -p /etc/systemd/system/idle-watchdog.service.d
cat > /etc/systemd/system/idle-watchdog.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

mkdir -p /etc/systemd/system/spot-monitor.service.d
cat > /etc/systemd/system/spot-monitor.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

# 1. Start ComfyUI
echo "--- Starting ComfyUI ---"
systemctl daemon-reload
systemctl start comfyui

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8188/system_stats > /dev/null 2>&1; then
        echo "ComfyUI ready after ${i}s"
        break
    fi
    sleep 2
done

# 2. Start quick tunnel
echo "--- Starting quick tunnel ---"
cloudflared tunnel --url http://localhost:8188 --no-autoupdate > /tmp/tunnel.log 2>&1 &

# Wait for tunnel URL (grep -oE for portability — no PCRE dependency)
TUNNEL_URL=""
for i in $(seq 1 30); do
    sleep 1
    TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
done

if [ -n "$TUNNEL_URL" ]; then
    echo "Tunnel URL: $TUNNEL_URL"
    python3 -c "
import boto3
ssm = boto3.client('ssm', region_name='$REGION')
ssm.put_parameter(Name='/prismata-3d/tunnel-url/$INSTANCE_ID', Value='$TUNNEL_URL', Type='String', Overwrite=True)
print('Tunnel URL written to SSM')
" || echo "Failed to write tunnel URL to SSM"
else
    echo "WARNING: Tunnel URL not captured after 30s"
fi

# 3. Start monitoring (services are baked into AMI, just start them)
echo "--- Starting monitoring ---"
systemctl start idle-watchdog
systemctl start spot-monitor

echo "=== Boot complete $(date) ==="
