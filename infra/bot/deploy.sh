#!/bin/bash
# infra/bot/deploy.sh
# Deploy the Discord bot to prismata-data server.
#
# Usage: bash infra/bot/deploy.sh <ssh-host>
# Example: bash infra/bot/deploy.sh ubuntu@1.2.3.4

set -euo pipefail

SSH_HOST="${1:-}"

if [ -z "$SSH_HOST" ]; then
    echo "Usage: bash deploy.sh <ssh-host>"
    echo "Example: bash deploy.sh ubuntu@1.2.3.4"
    exit 1
fi

REMOTE_DIR="/opt/prismata-3d-bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Prismata 3D Bot ==="
echo "Host: $SSH_HOST"
echo "Remote dir: $REMOTE_DIR"
echo ""

# Create remote directory
ssh "$SSH_HOST" "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"

# Sync bot files
rsync -avz \
    "$SCRIPT_DIR/bot.py" \
    "$SCRIPT_DIR/ec2_manager.py" \
    "$SCRIPT_DIR/config.py" \
    "$SCRIPT_DIR/requirements.txt" \
    "$SSH_HOST:$REMOTE_DIR/"

# Install dependencies
ssh "$SSH_HOST" "cd $REMOTE_DIR && pip3 install -r requirements.txt"

# Create systemd service
REMOTE_USER=$(ssh "$SSH_HOST" "whoami")
ssh "$SSH_HOST" "sudo tee /etc/systemd/system/prismata-3d-bot.service > /dev/null" <<EOF
[Unit]
Description=Prismata 3D Generation Discord Bot
After=network.target

[Service]
Type=simple
User=$REMOTE_USER
WorkingDirectory=$REMOTE_DIR
ExecStart=/usr/bin/python3 $REMOTE_DIR/bot.py
EnvironmentFile=-/etc/prismata-3d-bot.env
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Next steps on the server:"
echo "  1. Create /etc/prismata-3d-bot.env with:"
echo "     DISCORD_TOKEN=your_bot_token_here"
echo "     AWS_REGION=us-east-1"
echo "  2. Start the bot:"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable prismata-3d-bot"
echo "     sudo systemctl start prismata-3d-bot"
echo "  3. Check logs:"
echo "     journalctl -u prismata-3d-bot -f"
