#!/bin/bash
# infra/frontend/deploy.sh
# Deploy the Fabrication Terminal frontend to a running ComfyUI instance.
# Usage: ./deploy.sh <tunnel-url-or-ip>
#   e.g., ./deploy.sh https://random-words.trycloudflare.com
#   e.g., ./deploy.sh i-0abc123def456  (uses SSM to deploy)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND_HTML="$SCRIPT_DIR/index.html"

if [ ! -f "$FRONTEND_HTML" ]; then
    echo "ERROR: index.html not found at $FRONTEND_HTML"
    exit 1
fi

# ── Deploy via SSM (instance ID) ──
deploy_ssm() {
    local instance_id="$1"
    echo "Deploying via SSM to instance $instance_id..."

    # Upload the HTML file via S3 (SSM send-command has a size limit)
    aws s3 cp "$FRONTEND_HTML" s3://prismata-3d-models/frontend/index.html --region us-east-1
    echo "Uploaded to S3"

    # Run install command on instance
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[
            'set -e',
            'COMFYUI_WEB=/opt/comfyui/web',
            'FABRICATE_DIR=\$COMFYUI_WEB/fabricate',
            'mkdir -p \$FABRICATE_DIR',
            'aws s3 cp s3://prismata-3d-models/frontend/index.html \$FABRICATE_DIR/index.html --region us-east-1',
            'cp /opt/prismata-3d/assets/manifest.json \$FABRICATE_DIR/manifest.json',
            'cp /opt/prismata-3d/assets/descriptions.json \$FABRICATE_DIR/descriptions.json',
            'chown -R comfyui:comfyui \$FABRICATE_DIR',
            'echo Frontend deployed to \$FABRICATE_DIR'
        ]" \
        --region us-east-1 \
        --query "Command.CommandId" --output text)

    echo "SSM command sent: $cmd_id"
    echo "Waiting for completion..."
    aws ssm wait command-executed \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region us-east-1 2>/dev/null || true

    # Get output
    aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region us-east-1 \
        --query "[StatusDetails, StandardOutputContent, StandardErrorContent]" \
        --output text

    echo ""
    echo "Frontend should be accessible at: <tunnel-url>/fabricate/index.html"
}

# ── Deploy via direct upload (tunnel URL) ──
deploy_direct() {
    local url="$1"
    echo "Direct upload not supported — ComfyUI doesn't have an upload endpoint for web files."
    echo "Use SSM deployment instead: $0 <instance-id>"
    echo ""
    echo "Or manually copy:"
    echo "  1. scp $FRONTEND_HTML ubuntu@<ip>:/tmp/fabricate.html"
    echo "  2. ssh ubuntu@<ip> 'sudo mkdir -p /opt/comfyui/web/fabricate && sudo mv /tmp/fabricate.html /opt/comfyui/web/fabricate/index.html && sudo cp /opt/prismata-3d/assets/manifest.json /opt/comfyui/web/fabricate/ && sudo chown -R comfyui:comfyui /opt/comfyui/web/fabricate'"
    exit 1
}

# ── Main ──
if [ $# -lt 1 ]; then
    echo "Usage: $0 <instance-id>"
    echo "  e.g., $0 i-0abc123def456"
    exit 1
fi

TARGET="$1"

if [[ "$TARGET" == i-* ]]; then
    deploy_ssm "$TARGET"
elif [[ "$TARGET" == http* ]]; then
    deploy_direct "$TARGET"
else
    echo "Unrecognized target: $TARGET"
    echo "Expected instance ID (i-xxx) or URL (https://...)"
    exit 1
fi
