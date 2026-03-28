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
import os, json, tempfile

FABRICATE_DIR = os.path.join(os.path.dirname(__file__), "web")
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "output")
NODE_CLASS_MAPPINGS = {}
S3_BUCKET = "prismata-3d-models"
S3_REGION = "us-east-1"

def _s3():
    import boto3
    return boto3.client("s3", region_name=S3_REGION)

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

@PromptServer.instance.routes.post("/fabricate/metadata")
async def save_metadata(request):
    try:
        data = await request.json()
        filename = data.get("filename", "")
        if not filename or ".." in filename or "/" in filename:
            return web.Response(status=400, text="Invalid filename")
        meta_path = os.path.join(OUTPUT_DIR, filename + ".params.json")
        with open(meta_path, "w") as f:
            json.dump(data, f, indent=2)
        return web.json_response({"ok": True})
    except Exception as e:
        return web.Response(status=500, text=str(e))

@PromptServer.instance.routes.get("/fabricate/api/s3-check/{unit}/{skin}")
async def s3_check(request):
    """Check if a model exists in S3 and return its metadata."""
    unit = request.match_info["unit"]
    skin = request.match_info["skin"]
    try:
        s3 = _s3()
        prefix = f"models/{unit}/{skin}/"
        resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=prefix)
        if resp.get("KeyCount", 0) == 0:
            return web.json_response({"exists": False})
        files = []
        meta = None
        for obj in resp.get("Contents", []):
            key = obj["Key"]
            name = key.split("/")[-1]
            if name.endswith(".meta.json"):
                # Get latest metadata
                try:
                    m = s3.get_object(Bucket=S3_BUCKET, Key=key)
                    meta = json.loads(m["Body"].read().decode())
                except Exception:
                    pass
            elif name.startswith("latest."):
                continue
            elif not name.endswith(".json"):
                files.append({"key": key, "name": name, "size": obj["Size"],
                              "modified": obj["LastModified"].isoformat()})
        files.sort(key=lambda f: f["modified"], reverse=True)
        return web.json_response({"exists": True, "files": files, "meta": meta})
    except Exception as e:
        return web.json_response({"exists": False, "error": str(e)})

@PromptServer.instance.routes.get("/fabricate/api/s3-model/{unit}/{skin}")
async def s3_model(request):
    """Download latest model from S3 and serve it."""
    unit = request.match_info["unit"]
    skin = request.match_info["skin"]
    fmt = request.query.get("format", "glb")
    try:
        s3 = _s3()
        key = f"models/{unit}/{skin}/latest.{fmt}"
        obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
        body = obj["Body"].read()
        content_type = "model/gltf-binary" if fmt == "glb" else "application/octet-stream"
        return web.Response(body=body, content_type=content_type,
                          headers={"Content-Disposition": f"inline; filename=latest.{fmt}"})
    except s3.exceptions.NoSuchKey:
        return web.Response(status=404, text="No model found")
    except Exception as e:
        return web.Response(status=500, text=str(e))

@PromptServer.instance.routes.get("/fabricate/api/s3-list")
async def s3_list_all(request):
    """List all units that have models in S3."""
    try:
        s3 = _s3()
        resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix="models/", Delimiter="/")
        units = {}
        for prefix in resp.get("CommonPrefixes", []):
            unit = prefix["Prefix"].split("/")[1]
            # List skins for this unit
            skin_resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=f"models/{unit}/", Delimiter="/")
            skins = [p["Prefix"].split("/")[2] for p in skin_resp.get("CommonPrefixes", [])]
            if skins:
                units[unit] = skins
        return web.json_response(units)
    except Exception as e:
        return web.json_response({"error": str(e)})

@PromptServer.instance.routes.post("/fabricate/api/favorite")
async def s3_favorite(request):
    """Mark a model as favorited in S3."""
    try:
        data = await request.json()
        unit = data.get("unit", "")
        skin = data.get("skin", "")
        filename = data.get("filename", "")
        if not unit or not skin or not filename:
            return web.Response(status=400, text="Missing fields")
        s3 = _s3()
        fav = {
            "unit": unit, "skin": skin, "filename": filename,
            "params": data.get("params"),
            "favorited_at": __import__("datetime").datetime.utcnow().isoformat() + "Z"
        }
        key = f"favorites/{unit}/{skin}/{filename}.fav.json"
        s3.put_object(Bucket=S3_BUCKET, Key=key, Body=json.dumps(fav, indent=2),
                     ContentType="application/json")
        return web.json_response({"ok": True})
    except Exception as e:
        return web.Response(status=500, text=str(e))

@PromptServer.instance.routes.get("/fabricate/api/favorites")
async def s3_list_favorites(request):
    """List all favorited models."""
    try:
        s3 = _s3()
        resp = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix="favorites/")
        favs = []
        for obj in resp.get("Contents", []):
            if obj["Key"].endswith(".fav.json"):
                try:
                    m = s3.get_object(Bucket=S3_BUCKET, Key=obj["Key"])
                    fav = json.loads(m["Body"].read().decode())
                    favs.append(fav)
                except Exception:
                    pass
        return web.json_response(favs)
    except Exception as e:
        return web.json_response([])

@PromptServer.instance.routes.post("/fabricate/api/reject")
async def s3_reject(request):
    """Mark a model as a bad generation in S3."""
    try:
        data = await request.json()
        unit = data.get("unit", "")
        skin = data.get("skin", "")
        filename = data.get("filename", "")
        if not unit or not skin or not filename:
            return web.Response(status=400, text="Missing fields")
        s3 = _s3()
        import datetime
        rej = {
            "unit": unit, "skin": skin, "filename": filename,
            "params": data.get("params"),
            "rejected_at": datetime.datetime.utcnow().isoformat() + "Z"
        }
        key = f"rejections/{unit}/{skin}/{filename}.rej.json"
        s3.put_object(Bucket=S3_BUCKET, Key=key, Body=json.dumps(rej, indent=2),
                     ContentType="application/json")
        return web.json_response({"ok": True})
    except Exception as e:
        return web.Response(status=500, text=str(e))
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
