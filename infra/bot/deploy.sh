#!/bin/bash
# infra/bot/deploy.sh
# Deploy the Discord bot to prismata-data server.
#
# Usage: bash infra/bot/deploy.sh <ssh-host>
# Example: bash infra/bot/deploy.sh ubuntu@1.2.3.4

set -euo pipefail

SSH_KEY="$HOME/.ssh/<SSH_KEY>.pem"
SSH_HOST="ubuntu@<DATA_BOX_PUBLIC_IP>"
SSH="ssh -i $SSH_KEY $SSH_HOST"
SCP="scp -i $SSH_KEY"

REMOTE_DIR="/opt/prismata-3d-bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Prismata 3D Bot ==="
echo "Host: $SSH_HOST"
echo "Remote dir: $REMOTE_DIR"
echo ""

# Create remote directory
$SSH "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"

# Copy bot files
for f in bot.py ec2_manager.py config.py requirements.txt; do
    $SCP "$SCRIPT_DIR/$f" "$SSH_HOST:$REMOTE_DIR/"
done

# Install dependencies in venv
$SSH "cd $REMOTE_DIR && python3 -m venv venv && ./venv/bin/pip install -q -r requirements.txt"

# Create systemd service
$SSH "sudo tee /etc/systemd/system/prismata-3d-bot.service > /dev/null" <<EOF
[Unit]
Description=Prismata 3D Generation Discord Bot
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=$REMOTE_DIR
ExecStart=$REMOTE_DIR/venv/bin/python $REMOTE_DIR/bot.py
EnvironmentFile=/etc/prismata-3d-bot.env
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Reload and restart
$SSH "sudo systemctl daemon-reload && sudo systemctl enable prismata-3d-bot && sudo systemctl restart prismata-3d-bot"

sleep 3
echo ""
$SSH "sudo systemctl status prismata-3d-bot --no-pager"
