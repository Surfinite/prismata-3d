#!/bin/bash
# infra/ami/install-frontend.sh
# Install the Fabrication Terminal frontend as a ComfyUI custom node.
# ComfyUI doesn't serve arbitrary files from web/, so we register a
# custom node that adds /fabricate/ routes via aiohttp.
# Run during AMI build (after install-comfyui.sh and install-assets.sh).
set -euo pipefail

echo "=== Installing Fabrication Terminal frontend ==="

COMFYUI_DIR="/opt/comfyui"
FABRICATE_NODE="$COMFYUI_DIR/custom_nodes/fabricate"
ASSET_DIR="/opt/prismata-3d/assets"

# Create custom node directory structure
mkdir -p "$FABRICATE_NODE/web"

# Copy frontend from S3 (uploaded by CI or deploy script)
aws s3 cp s3://prismata-3d-models/frontend/index.html "$FABRICATE_NODE/web/index.html" --region us-east-1

# Copy manifest and descriptions alongside the HTML for fast loading
cp "$ASSET_DIR/manifest.json" "$FABRICATE_NODE/web/manifest.json"
cp "$ASSET_DIR/descriptions.json" "$FABRICATE_NODE/web/descriptions.json"

# Create the custom node Python file that registers /fabricate/ routes
cat > "$FABRICATE_NODE/__init__.py" << 'PYEOF'
from aiohttp import web
from server import PromptServer
import os

FABRICATE_DIR = os.path.join(os.path.dirname(__file__), "web")
NODE_CLASS_MAPPINGS = {}

@PromptServer.instance.routes.get("/fabricate")
@PromptServer.instance.routes.get("/fabricate/")
async def serve_fabricate_index(request):
    return web.FileResponse(os.path.join(FABRICATE_DIR, "index.html"))

@PromptServer.instance.routes.get("/fabricate/{path:.+}")
async def serve_fabricate_file(request):
    path = request.match_info["path"]
    file_path = os.path.join(FABRICATE_DIR, path)
    if os.path.isfile(file_path):
        return web.FileResponse(file_path)
    return web.Response(status=404, text="Not found")
PYEOF

# Also keep a copy in web/fabricate for backwards compatibility
mkdir -p "$COMFYUI_DIR/web/fabricate"
cp "$FABRICATE_NODE/web/index.html" "$COMFYUI_DIR/web/fabricate/index.html"
cp "$FABRICATE_NODE/web/manifest.json" "$COMFYUI_DIR/web/fabricate/manifest.json"
cp "$FABRICATE_NODE/web/descriptions.json" "$COMFYUI_DIR/web/fabricate/descriptions.json"

# Set ownership
chown -R comfyui:comfyui "$FABRICATE_NODE"
chown -R comfyui:comfyui "$COMFYUI_DIR/web/fabricate"

echo "Fabrication Terminal installed as custom node at $FABRICATE_NODE"
echo "Access via: <tunnel-url>/fabricate/"
echo "=== Frontend install complete ==="
