#!/bin/bash
# infra/ami/install-nvidia.sh
# Verify NVIDIA drivers (pre-installed in AWS Deep Learning AMI) and install CUDA toolkit.
# No reboot needed — the Deep Learning AMI ships with drivers already loaded.
set -euo pipefail

echo "=== Verifying NVIDIA drivers + installing CUDA toolkit ==="

# The Deep Learning Base AMI has NVIDIA drivers pre-installed.
# Verify they work before proceeding.
if ! nvidia-smi > /dev/null 2>&1; then
    echo "ERROR: nvidia-smi failed. This script expects the AWS Deep Learning Base AMI"
    echo "with NVIDIA drivers pre-installed. If using stock Ubuntu, install drivers manually."
    exit 1
fi

echo "NVIDIA driver verified:"
nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader

# Install CUDA toolkit 12.4 (the AMI may have a different CUDA version or just the driver)
# Add NVIDIA CUDA repo for the toolkit
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
rm cuda-keyring_1.1-1_all.deb
apt-get update

# Install only the toolkit, NOT cuda-drivers (drivers already present)
DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-12-4

# Set up environment
if [ ! -f /etc/profile.d/cuda.sh ]; then
    cat >> /etc/profile.d/cuda.sh <<'ENVEOF'
export PATH=/usr/local/cuda-12.4/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64:${LD_LIBRARY_PATH:-}
ENVEOF
    chmod +x /etc/profile.d/cuda.sh
fi

echo "=== NVIDIA + CUDA toolkit install complete ==="
