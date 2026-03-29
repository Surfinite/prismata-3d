#!/bin/bash
# infra/ec2/warmup.sh
# Submits a minimal Hunyuan3D generation to pre-load the v2.0 shape model
# into GPU VRAM. Uses drone/Regular sprite, 1 step, octree 128.
# Output is discarded — this runs BEFORE output-sync starts.

set -euo pipefail

COMFYUI_URL="http://localhost:8188"
MANIFEST="/opt/prismata-3d/assets/manifest.json"
OUTPUT_DIR="/opt/comfyui/output"
WARMUP_PREFIX="__warmup__"

log() { echo "[warmup $(date +%H:%M:%S)] $*"; }

# Wait for ComfyUI to be ready (up to 3 minutes)
log "Waiting for ComfyUI to be ready..."
READY=false
for i in $(seq 1 90); do
    if curl -sf "$COMFYUI_URL/system_stats" > /dev/null 2>&1; then
        log "ComfyUI ready after ${i}s"
        READY=true
        break
    fi
    sleep 2
done
if [ "$READY" = "false" ]; then
    log "ERROR: ComfyUI not ready after 180s, skipping warmup"
    exit 1
fi

# Get drone Regular image path from manifest
IMAGE_PATH=""
if [ -f "$MANIFEST" ]; then
    IMAGE_PATH=$(python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
# Try 'drone' then 'Drone' — manifest keys are lowercase
for key in ['drone', 'Drone']:
    if key in m:
        skins = m[key]
        for skin in ['Regular', 'regular']:
            if skin in skins:
                print(skins[skin])
                break
        break
" 2>/dev/null || true)
fi

if [ -z "$IMAGE_PATH" ]; then
    log "WARNING: Could not find drone/Regular in manifest, skipping warmup"
    exit 0
fi

COMFY_IMAGE="prismata-assets/$IMAGE_PATH"
log "Warming up v2.0 shape model with: $COMFY_IMAGE"

# Build minimal workflow: LoadImage → ModelLoader → GenerateMesh → VAEDecode → ExportMesh
# Steps=1, octree=128, no texture, no postprocessing — just enough to load weights
WORKFLOW=$(cat <<'WEOF'
{
  "1": {
    "class_type": "LoadImage",
    "inputs": { "image": "__IMAGE__" }
  },
  "2": {
    "class_type": "Hy3DModelLoader",
    "inputs": {
      "model": "hunyuan3d/hunyuan3d-dit-v2-0.safetensors",
      "attention_mode": "sdpa"
    }
  },
  "3": {
    "class_type": "Hy3DGenerateMesh",
    "inputs": {
      "pipeline": ["2", 0],
      "image": ["1", 0],
      "steps": 1,
      "guidance_scale": 5.5,
      "seed": 42
    }
  },
  "4": {
    "class_type": "Hy3DVAEDecode",
    "inputs": {
      "vae": ["2", 1],
      "latents": ["3", 0],
      "box_v": 1.01,
      "octree_resolution": 128,
      "num_chunks": 8000,
      "mc_level": 0,
      "mc_algo": "mc",
      "enable_flash_vdm": true,
      "force_offload": false
    }
  },
  "5": {
    "class_type": "Hy3DExportMesh",
    "inputs": {
      "trimesh": ["4", 0],
      "file_format": "glb",
      "filename_prefix": "__warmup__"
    }
  }
}
WEOF
)

# Substitute the actual image path
WORKFLOW=$(echo "$WORKFLOW" | sed "s|__IMAGE__|$COMFY_IMAGE|g")

# Submit to ComfyUI API
log "Submitting warmup workflow..."
RESP=$(curl -sf -X POST "$COMFYUI_URL/api/prompt" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": $WORKFLOW}" 2>&1) || {
    log "ERROR: Failed to submit warmup workflow: $RESP"
    exit 1
}

PROMPT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt_id'])" 2>/dev/null || true)
if [ -z "$PROMPT_ID" ]; then
    log "ERROR: No prompt_id in response: $RESP"
    exit 1
fi

log "Warmup queued (prompt_id: $PROMPT_ID). Waiting for completion..."

# Poll for completion (timeout after 3 minutes)
TIMEOUT=180
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))

    STATUS=$(curl -sf "$COMFYUI_URL/api/history/$PROMPT_ID" 2>/dev/null || echo "{}")
    # History entry exists once the prompt is done (success or failure)
    HAS_ENTRY=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('yes' if '$PROMPT_ID' in d else 'no')
" 2>/dev/null || echo "no")

    if [ "$HAS_ENTRY" = "yes" ]; then
        log "Warmup generation complete (${ELAPSED}s)"
        break
    fi
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    log "WARNING: Warmup timed out after ${TIMEOUT}s (model may still be loading)"
fi

# Clean up warmup output files — do NOT let them sync to S3
rm -f "$OUTPUT_DIR"/${WARMUP_PREFIX}* 2>/dev/null || true
log "Cleaned up warmup output files"

log "GPU VRAM warm — v2.0 shape model loaded"
