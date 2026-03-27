#!/bin/bash
# infra/ami/install-nvidia.sh
# Install NVIDIA drivers + CUDA 12.4 on Ubuntu 22.04 for g5.xlarge (A10G)
# NOTE: A reboot is REQUIRED after this script before GPU is usable.
# The build script handles the reboot between this and install-comfyui.sh.
set -euo pipefail

echo "=== Installing NVIDIA drivers + CUDA 12.4 ==="

# Add NVIDIA CUDA repo
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
rm cuda-keyring_1.1-1_all.deb
apt-get update

# Install CUDA toolkit 12.4 (includes compatible driver)
DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-12-4 cuda-drivers

# Set up environment (available after reboot)
cat >> /etc/profile.d/cuda.sh <<'ENVEOF'
export PATH=/usr/local/cuda-12.4/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64:${LD_LIBRARY_PATH:-}
ENVEOF
chmod +x /etc/profile.d/cuda.sh

echo "=== NVIDIA install complete — REBOOT REQUIRED ==="
