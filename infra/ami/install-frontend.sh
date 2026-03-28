#!/bin/bash
# infra/ami/install-frontend.sh
# Install the Fabrication Terminal frontend into the ComfyUI web directory.
# Run during AMI build (after install-comfyui.sh and install-assets.sh).
set -euo pipefail

echo "=== Installing Fabrication Terminal frontend ==="

COMFYUI_WEB="/opt/comfyui/web"
FABRICATE_DIR="$COMFYUI_WEB/fabricate"
ASSET_DIR="/opt/prismata-3d/assets"

mkdir -p "$FABRICATE_DIR"

# Copy frontend from S3 (uploaded by CI or deploy script)
aws s3 cp s3://prismata-3d-models/frontend/index.html "$FABRICATE_DIR/index.html" --region us-east-1

# Copy manifest and descriptions alongside the HTML for fast loading
cp "$ASSET_DIR/manifest.json" "$FABRICATE_DIR/manifest.json"
cp "$ASSET_DIR/descriptions.json" "$FABRICATE_DIR/descriptions.json"

# Set ownership
chown -R comfyui:comfyui "$FABRICATE_DIR"

echo "Fabrication Terminal installed at $FABRICATE_DIR"
echo "Access via: <tunnel-url>/fabricate/index.html"
echo "=== Frontend install complete ==="
