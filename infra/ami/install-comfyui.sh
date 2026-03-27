#!/bin/bash
# infra/ami/install-comfyui.sh
# Install ComfyUI + Hunyuan3D wrapper + model weights.
# PREREQUISITE: install-nvidia.sh must have run AND instance must have rebooted
# so that nvidia-smi works and CUDA extensions can compile against the GPU.
set -euo pipefail

echo "=== Installing ComfyUI + Hunyuan3D ==="

# Verify GPU is available (catches missing reboot)
if ! nvidia-smi > /dev/null 2>&1; then
    echo "ERROR: nvidia-smi failed. Did you reboot after install-nvidia.sh?"
    exit 1
fi

COMFYUI_DIR="/opt/comfyui"
VENV_DIR="/opt/comfyui-env"

# System deps — Ubuntu 22.04 ships Python 3.10, which ComfyUI supports
apt-get update
apt-get install -y git python3-venv python3-dev build-essential ninja-build

# Create Python venv (uses system python3 = 3.10 on Ubuntu 22.04)
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
export PATH="/usr/local/cuda-12.4/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda-12.4/lib64:${LD_LIBRARY_PATH:-}"

# PyTorch with CUDA 12.4
pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Clone ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
cd "$COMFYUI_DIR"
pip install --no-cache-dir -r requirements.txt

# Install Hunyuan3D wrapper (kijai)
cd "$COMFYUI_DIR/custom_nodes"
git clone https://github.com/kijai/ComfyUI-Hunyuan3DWrapper.git
cd ComfyUI-Hunyuan3DWrapper
pip install --no-cache-dir -r requirements.txt

# Build texture rasterizer (required for textured output — needs GPU)
cd hy3dgen/texgen/custom_rasterizer
python setup.py install
cd ../../..

# Build differentiable renderer (optional but improves texture quality)
cd hy3dgen/texgen/differentiable_renderer
python setup.py build_ext --inplace
cd ../../..

# Install extra mesh processing deps
pip install --no-cache-dir -r requirements_extras.txt || echo "Some extras failed — non-critical"

# Pre-download model weights via HuggingFace (~20-30GB, takes 10-20 min)
pip install --no-cache-dir huggingface_hub

python3 -c "
from huggingface_hub import snapshot_download
import os

models_dir = '$COMFYUI_DIR/models'

# Hunyuan3D shape models (safetensors format for ComfyUI)
snapshot_download(
    'Kijai/Hunyuan3D-2_safetensors',
    local_dir=os.path.join(models_dir, 'diffusion_models', 'hunyuan3d'),
    local_dir_use_symlinks=False
)

# Texture paint model + other components (auto-download at runtime,
# but pre-caching avoids first-run delay for the user)
snapshot_download(
    'tencent/Hunyuan3D-2',
    local_dir=os.path.join(models_dir, 'hunyuan3d-cache'),
    local_dir_use_symlinks=False,
    allow_patterns=['*.json', '*.txt', '*.safetensors', '*.bin'],
    ignore_patterns=['*.md', '*.git*', 'assets/*']
)

print('Model weights downloaded successfully')
"

# Create service user with a home dir (HuggingFace cache writes to ~/.cache)
useradd -r -m -d /opt/comfyui-home -s /bin/false comfyui || true
chown -R comfyui:comfyui "$COMFYUI_DIR"
chown -R comfyui:comfyui "$VENV_DIR"
chown -R comfyui:comfyui /opt/comfyui-home

echo "=== ComfyUI + Hunyuan3D install complete ==="
echo "ComfyUI dir: $COMFYUI_DIR"
echo "Venv: $VENV_DIR"
