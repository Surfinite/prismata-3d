#!/bin/bash
# EC2 instance boot script. Runs as root via user-data.
# ComfyUI, monitoring scripts, and systemd services are
# pre-installed in the AMI. This script just starts them and injects
# runtime config (webhook URL).
#
# NOTE: Launch template v12 sets InstanceInitiatedShutdownBehavior: terminate.
# The idle watchdog's "shutdown -h now" will TERMINATE (not just stop) this
# instance, ensuring no zombie stopped instances accumulate.

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

# 1b. Warmup: pre-load v2.0 shape model into GPU VRAM
# Runs before output-sync starts so warmup output won't upload to S3
echo "--- Warming up GPU (shape model pre-load) ---"
# Download latest warmup script from S3 (works even before AMI rebuild)
aws s3 cp s3://prismata-3d-models/scripts/warmup.sh /opt/prismata-3d/warmup.sh --region "$REGION" 2>/dev/null || true
chmod +x /opt/prismata-3d/warmup.sh 2>/dev/null || true
bash /opt/prismata-3d/warmup.sh &
WARMUP_PID=$!

# 2. Wait for warmup to finish before starting output-sync (prevents warmup files uploading to S3)
if [ -n "${WARMUP_PID:-}" ]; then
    echo "Waiting for GPU warmup to complete..."
    wait "$WARMUP_PID" || echo "WARNING: Warmup exited with non-zero status (non-fatal)"
fi

# 3. Start monitoring and output sync (services are baked into AMI, just start them)
echo "--- Starting monitoring ---"
systemctl start idle-watchdog
systemctl start spot-monitor
systemctl start output-sync

echo "=== Boot complete $(date) ==="
