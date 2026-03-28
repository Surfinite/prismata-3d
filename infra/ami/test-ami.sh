#!/bin/bash
# infra/ami/test-ami.sh
# Smoke test: verify GPU, ComfyUI, and Hunyuan3D are working.
# Run on the build instance after all install scripts.
set -euo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        $output" | head -3
        FAIL=$((FAIL + 1))
    fi
}

echo "=== AMI Smoke Test ==="

# GPU
check "nvidia-smi runs" nvidia-smi
check "CUDA toolkit present" /usr/local/cuda-12.4/bin/nvcc --version

# Python environment
check "venv exists" test -d /opt/comfyui-env
check "torch imports" /opt/comfyui-env/bin/python -c "import torch; assert torch.cuda.is_available(), 'no GPU'"
check "torch sees GPU" /opt/comfyui-env/bin/python -c "import torch; print(torch.cuda.get_device_name(0))"

# ComfyUI
check "ComfyUI directory exists" test -d /opt/comfyui
check "ComfyUI main.py exists" test -f /opt/comfyui/main.py
check "Hunyuan3D wrapper installed" test -d /opt/comfyui/custom_nodes/ComfyUI-Hunyuan3DWrapper

# Model weights (only shape model is pre-downloaded; paint model auto-downloads at runtime)
check "Shape model present" test -d /opt/comfyui/models/diffusion_models/hunyuan3d

# Assets
check "Asset manifest present" test -f /opt/prismata-3d/assets/manifest.json
check "Asset descriptions present" test -f /opt/prismata-3d/assets/descriptions.json
check "Sprites present" test -d /opt/prismata-3d/assets/units

# Services
check "comfyui.service installed" test -f /etc/systemd/system/comfyui.service
check "cloudflared installed" which cloudflared
check "idle-watchdog.sh present" test -f /opt/prismata-3d/idle-watchdog.sh
check "spot-monitor.sh present" test -f /opt/prismata-3d/spot-monitor.sh

# Start ComfyUI and verify it responds
echo "  Starting ComfyUI for health check..."
systemctl start comfyui
for i in $(seq 1 60); do
    if curl -sf http://localhost:8188/system_stats > /dev/null 2>&1; then
        echo "  PASS: ComfyUI responds on port 8188 (took ${i}s)"
        PASS=$((PASS + 1))
        break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
        echo "  FAIL: ComfyUI did not respond within 120s"
        FAIL=$((FAIL + 1))
    fi
done
systemctl stop comfyui

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
