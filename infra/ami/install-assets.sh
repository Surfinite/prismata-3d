#!/bin/bash
# infra/ami/install-assets.sh
# Download prepared asset data from S3 into the AMI
set -euo pipefail

echo "=== Installing Prismata asset data ==="

ASSET_DIR="/opt/prismata-3d/assets"
mkdir -p "$ASSET_DIR"

# Download from S3 (uploaded by Phase 0 run_all.py)
aws s3 sync "s3://prismata-3d-models/asset-prep/" "$ASSET_DIR/" --region us-east-1

# Verify key files exist
for f in manifest.json descriptions.json; do
    if [ ! -f "$ASSET_DIR/$f" ]; then
        echo "ERROR: $ASSET_DIR/$f not found"
        exit 1
    fi
done

# Count sprites
SPRITE_COUNT=$(find "$ASSET_DIR/units" -name "*.png" | wc -l)
echo "Asset data installed: $SPRITE_COUNT sprites"

# Also symlink into ComfyUI input directory for easy access
ln -sf "$ASSET_DIR" /opt/comfyui/input/prismata-assets

# Set ownership
chown -R comfyui:comfyui "$ASSET_DIR"

echo "=== Asset install complete ==="
