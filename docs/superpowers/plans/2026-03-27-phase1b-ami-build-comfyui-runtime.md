# Phase 1B: AMI Build + ComfyUI Runtime — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a custom AMI with Hunyuan3D 2.0 + ComfyUI pre-installed, so that `!start` in Discord launches a GPU instance with a working 3D generation UI accessible via quick tunnel.

**Architecture:** A Packer build script creates a custom AMI from Ubuntu 22.04 + NVIDIA drivers + CUDA + ComfyUI + Hunyuan3D wrapper nodes + pre-downloaded model weights. On boot, `user-data.sh` starts ComfyUI as a systemd service, opens a quick tunnel, and posts the URL to Discord via SSM. The existing idle watchdog and spot monitor run unchanged.

**Tech Stack:** Bash (AMI build), ComfyUI (web UI + API), ComfyUI-Hunyuan3DWrapper (kijai), PyTorch 2.5+ with CUDA 12.4, cloudflared (quick tunnel), systemd

---

## Scope

This plan covers getting a **single unit generating end-to-end** via ComfyUI's built-in UI. The custom frontend (unit selector, batch mode, etc.) is Phase 1C — we first prove the GPU pipeline works.

What's IN scope:
- AMI build script with all dependencies pre-baked
- ComfyUI + Hunyuan3D wrapper nodes installed and working
- Model weights pre-downloaded (DiT-v2-0, Paint-v2-0, mini variants)
- ComfyUI systemd service (starts on boot, port 8188)
- Updated `user-data.sh` to start ComfyUI instead of placeholder
- Asset data (sprites + descriptions) baked into AMI at `/opt/prismata-3d/assets/`
- Example workflow JSON for image-to-3D generation
- Updated launch template to use new AMI
- End-to-end test: `!start` → open tunnel URL → load workflow → generate a model

What's NOT in scope (Phase 1C+):
- Custom HTML frontend (unit selector, skin selector, batch)
- Job queue with persistence
- Thumbnail rendering
- S3 upload of outputs (manual `aws s3 cp` for now)
- Post-processing (decimation, normalization)
- "Send to Blender" button (see below)

### Phase 1C Feature: Send to Blender

A button in the custom frontend that downloads the generated GLB to the local machine and imports it into Blender via the MCP, with metadata attached as Blender custom properties so Claude can read context about the model:

**Flow:** Generate in ComfyUI → click "Send to Blender" → downloads GLB to `assets/models/{unit}/{skin}/` → Blender MCP imports it → attaches custom properties

**Blender custom properties (set on the imported object):**
- `prismata_unit`: unit name (e.g. "drone")
- `prismata_skin`: skin name (e.g. "Regular")
- `generation_model`: model variant used (e.g. "hunyuan3d-2.0")
- `generation_seed`: seed value
- `generation_steps`: inference steps
- `source_image`: path to the input sprite
- `suggested_cleanup`: notes for Claude about what to fix (e.g. "reduce to <5000 tris, fix normals, center pivot at bottom")

This gives Claude + Blender MCP a ready starting point: the model is loaded, and the properties tell it what unit it is, how it was generated, and what cleanup is needed. Claude can then refine the mesh, adjust materials, reduce poly count, and export the final version.

---

## File Structure

```
infra/ami/
  build-ami.sh              — Main AMI build script (runs on a fresh Ubuntu 22.04 instance)
  install-nvidia.sh         — NVIDIA driver + CUDA 12.4 installation
  install-comfyui.sh        — ComfyUI + Hunyuan3D wrapper + model weights
  comfyui.service           — systemd unit file for ComfyUI
  idle-watchdog.service     — systemd unit file for idle watchdog (baked into AMI)
  spot-monitor.service      — systemd unit file for spot monitor (baked into AMI)
  test-ami.sh               — Smoke test: verify ComfyUI starts and GPU is detected

infra/ec2/
  user-data.sh              — MODIFY: simplify (services baked into AMI, just start + tunnel)

infra/workflows/
  hunyuan3d-image-to-3d.json — ComfyUI workflow (API format) for single image → GLB
                               ⚠️ MANUAL GATE: created interactively after AMI boots (Task 7)
```

---

## Task 1: NVIDIA Driver + CUDA Install Script

**Files:**
- Create: `infra/ami/install-nvidia.sh`

This script installs NVIDIA drivers and CUDA toolkit on Ubuntu 22.04. It's designed to run during AMI baking (not on every boot).

- [ ] **Step 1: Create the NVIDIA install script**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add infra/ami/install-nvidia.sh
git commit -m "feat: add NVIDIA driver + CUDA 12.4 install script for AMI build"
```

---

## Task 2: ComfyUI + Hunyuan3D Install Script

**Files:**
- Create: `infra/ami/install-comfyui.sh`

This is the largest script — installs ComfyUI, the Hunyuan3D wrapper nodes, and pre-downloads model weights from HuggingFace.

- [ ] **Step 1: Create the ComfyUI install script**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add infra/ami/install-comfyui.sh
git commit -m "feat: add ComfyUI + Hunyuan3D wrapper install script with model weight download"
```

---

## Task 3: ComfyUI Systemd Service

**Files:**
- Create: `infra/ami/comfyui.service`

- [ ] **Step 1: Create the systemd unit file**

```ini
[Unit]
Description=ComfyUI - Hunyuan3D Generation Server
After=network.target

[Service]
Type=simple
User=comfyui
Group=comfyui
WorkingDirectory=/opt/comfyui
ExecStart=/opt/comfyui-env/bin/python main.py --listen 0.0.0.0 --port 8188 --preview-method auto
Environment=PYTHONUNBUFFERED=1
Environment=HOME=/opt/comfyui-home
Environment=PATH=/usr/local/cuda-12.4/bin:/usr/local/bin:/usr/bin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64
Restart=always
RestartSec=5

# Give it time to load models into VRAM
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Create idle-watchdog.service**

```ini
[Unit]
Description=Prismata 3D Gen Idle Watchdog
After=comfyui.service

[Service]
Type=simple
ExecStart=/opt/prismata-3d/idle-watchdog.sh
Environment=DISCORD_WEBHOOK_URL=
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Note: `DISCORD_WEBHOOK_URL` is set to empty here — `user-data.sh` overwrites this file at boot with the actual webhook URL from SSM. The service file in the AMI is a template.

- [ ] **Step 3: Create spot-monitor.service**

```ini
[Unit]
Description=Prismata 3D Gen Spot Monitor
After=network.target

[Service]
Type=simple
ExecStart=/opt/prismata-3d/spot-monitor.sh
Environment=DISCORD_WEBHOOK_URL=
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Commit**

```bash
git add infra/ami/comfyui.service infra/ami/idle-watchdog.service infra/ami/spot-monitor.service
git commit -m "feat: add systemd service files for ComfyUI, idle watchdog, and spot monitor"
```

---

## Task 4: Copy Asset Data Into AMI

**Files:**
- Create: `infra/ami/install-assets.sh`

The asset prep output (sprites + manifest + descriptions) needs to be on the AMI so the custom frontend (Phase 1C) can serve them, and so users can upload them manually via ComfyUI's image uploader for now.

- [ ] **Step 1: Create the asset install script**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add infra/ami/install-assets.sh
git commit -m "feat: add asset data install script for AMI (S3 → /opt/prismata-3d/assets/)"
```

---

## Task 5: Main AMI Build Script

**Files:**
- Create: `infra/ami/build-ami.sh`

This orchestrates the full AMI build. It launches a g5.xlarge instance (needs GPU for CUDA compilation), runs all install scripts, then creates an AMI snapshot.

- [ ] **Step 1: Create the build script**

```bash
#!/bin/bash
# infra/ami/build-ami.sh
# Build the Prismata 3D Gen AMI.
#
# This script:
# 1. Launches a temporary g5.xlarge from stock Ubuntu 22.04
# 2. Installs NVIDIA drivers, reboots, then installs ComfyUI + Hunyuan3D
# 3. Runs smoke tests, creates AMI, terminates build instance
#
# Usage: bash infra/ami/build-ami.sh
# Cost: ~$1-3 (g5.xlarge on-demand for ~1-1.5 hours)
#
# WARNING: Resource IDs below are project-specific (Surfinite's AWS account).
# Do not run this without updating them for your own environment.

set -euo pipefail

REGION="us-east-1"
BASE_AMI="ami-00de3875b03809ec5"          # Ubuntu 22.04 amd64 (us-east-1)
INSTANCE_TYPE="g5.xlarge"
KEY_NAME="prismata-spectator"              # EC2 key pair name
SECURITY_GROUP="sg-0fdc130ad1d5dc373"      # prismata-3d-gen security group
SSH_KEY="$HOME/.ssh/prismata-spectator.pem"
INSTANCE_PROFILE="prismata-3d-gen-profile" # IAM instance profile
AMI_NAME="prismata-3d-gen-v1-$(date +%Y%m%d)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building Prismata 3D Gen AMI ==="
echo "Base AMI: $BASE_AMI"
echo "Instance type: $INSTANCE_TYPE"
echo "Target AMI name: $AMI_NAME"
echo ""

# Ensure SSH inbound is open (add temp rule, ignore if already exists)
echo "--- Ensuring SSH access ---"
MY_IP=$(curl -s ifconfig.me)
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP" \
    --protocol tcp --port 22 --cidr "$MY_IP/32" --region "$REGION" 2>/dev/null || true

# Launch build instance
echo "--- Launching build instance ---"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP" \
    --iam-instance-profile Name="$INSTANCE_PROFILE" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ami-build-prismata-3d},{Key=Project,Value=prismata-3d-gen}]" \
    --query "Instances[0].InstanceId" \
    --output text \
    --region "$REGION")

echo "Build instance: $INSTANCE_ID"

# Cleanup trap: terminate instance if script fails
cleanup() {
    echo "--- Cleaning up: terminating build instance $INSTANCE_ID ---"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Get public IP
BUILD_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text \
    --region "$REGION")

echo "Build instance IP: $BUILD_IP"

wait_for_ssh() {
    echo "Waiting for SSH to be ready..."
    for i in $(seq 1 30); do
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            "ubuntu@$BUILD_IP" "echo ready" 2>/dev/null && return 0
        sleep 10
    done
    echo "ERROR: SSH not ready after 5 minutes"
    exit 1
}

wait_for_ssh

SSH="ssh -i $SSH_KEY ubuntu@$BUILD_IP"
SCP="scp -i $SSH_KEY"

# Upload all install scripts + service files
echo "--- Uploading install scripts ---"
for f in install-nvidia.sh install-comfyui.sh install-assets.sh comfyui.service \
         idle-watchdog.service spot-monitor.service test-ami.sh; do
    $SCP "$SCRIPT_DIR/$f" "ubuntu@$BUILD_IP:/tmp/"
done

# Phase 1: NVIDIA drivers (requires reboot before GPU is usable)
echo "--- Installing NVIDIA drivers + CUDA (~10 min) ---"
$SSH "sudo bash /tmp/install-nvidia.sh"

echo "--- Rebooting to load NVIDIA kernel module ---"
$SSH "sudo reboot" || true
sleep 30
wait_for_ssh

# Verify GPU is live after reboot
echo "--- Verifying GPU ---"
$SSH "nvidia-smi"

# Phase 2: ComfyUI + Hunyuan3D (needs working GPU for CUDA extension compilation)
echo "--- Installing ComfyUI + Hunyuan3D (~30-40 min, includes ~20GB model download) ---"
$SSH "sudo bash /tmp/install-comfyui.sh"

echo "--- Installing asset data ---"
$SSH "sudo bash /tmp/install-assets.sh"

# Install all systemd services (baked into AMI)
echo "--- Installing systemd services ---"
$SSH "sudo cp /tmp/comfyui.service /tmp/idle-watchdog.service /tmp/spot-monitor.service /etc/systemd/system/"
$SSH "sudo systemctl daemon-reload && sudo systemctl enable comfyui"

# Install cloudflared
echo "--- Installing cloudflared ---"
$SSH "sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb && sudo dpkg -i /tmp/cloudflared.deb"

# Copy monitoring scripts from S3 into AMI
echo "--- Installing monitoring scripts ---"
$SSH "sudo mkdir -p /opt/prismata-3d/output && sudo aws s3 cp s3://prismata-3d-models/scripts/idle-watchdog.sh /opt/prismata-3d/idle-watchdog.sh --region $REGION && sudo aws s3 cp s3://prismata-3d-models/scripts/spot-monitor.sh /opt/prismata-3d/spot-monitor.sh --region $REGION && sudo chmod +x /opt/prismata-3d/*.sh"

# Run smoke test
echo "--- Running smoke test ---"
$SSH "sudo bash /tmp/test-ami.sh"

# Clean up to reduce AMI size
echo "--- Cleaning up ---"
$SSH "sudo apt-get clean && sudo rm -rf /tmp/*.sh /tmp/*.deb /tmp/*.service /var/cache/apt/archives/* /home/ubuntu/.cache/pip"
$SSH "sudo systemctl stop comfyui 2>/dev/null || true"

# Create AMI
echo "--- Creating AMI (this takes ~10-15 min for ~50GB snapshot) ---"

AMI_ID=$(aws ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "Prismata 3D Gen: ComfyUI + Hunyuan3D 2.0 + asset data" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Project,Value=prismata-3d-gen},{Key=Version,Value=v1}]" \
    --output text \
    --region "$REGION")

echo "AMI creation started: $AMI_ID"
echo "Waiting for AMI to be available..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"

# Terminate build instance (trap will handle this, but be explicit)
echo "--- Terminating build instance ---"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
trap - EXIT  # Disarm cleanup trap

echo ""
echo "========================================="
echo "AMI built successfully!"
echo "AMI ID: $AMI_ID"
echo "AMI Name: $AMI_NAME"
echo "Estimated AMI storage: ~$2/month"
echo ""
echo "Next step: update the launch template:"
echo "  aws ec2 create-launch-template-version \\"
echo "    --launch-template-name prismata-3d-gen \\"
echo "    --source-version 1 \\"
echo "    --launch-template-data '{\"ImageId\":\"$AMI_ID\"}' \\"
echo "    --region $REGION"
echo ""
echo "Then set it as default:"
echo "  aws ec2 modify-launch-template \\"
echo "    --launch-template-name prismata-3d-gen \\"
echo "    --default-version 2 \\"
echo "    --region $REGION"
echo "========================================="
```

- [ ] **Step 2: Make executable**

```bash
chmod +x infra/ami/build-ami.sh
```

- [ ] **Step 3: Commit**

```bash
git add infra/ami/build-ami.sh
git commit -m "feat: add AMI build script orchestrating NVIDIA + ComfyUI + assets install"
```

---

## Task 6: Update user-data.sh for ComfyUI

**Files:**
- Modify: `infra/ec2/user-data.sh`

Replace the placeholder web server with ComfyUI startup. Since ComfyUI, cloudflared, and monitoring scripts are now baked into the AMI, user-data.sh becomes much simpler.

- [ ] **Step 1: Rewrite user-data.sh**

Replace the full file with:

```bash
#!/bin/bash
# EC2 instance boot script. Runs as root via user-data.
# ComfyUI, cloudflared, monitoring scripts, and systemd services are
# pre-installed in the AMI. This script just starts them and injects
# runtime config (webhook URL, tunnel URL).

set -euo pipefail
exec > /var/log/user-data.log 2>&1
echo "=== Prismata 3D Gen — Instance Boot $(date) ==="

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"

# Get instance ID
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/meta-data/instance-id")
echo "Instance ID: $INSTANCE_ID"

# Get Discord webhook URL from SSM and inject into monitoring services
DISCORD_WEBHOOK_URL=$(aws ssm get-parameter \
    --name /prismata-3d/discord-webhook-url \
    --region "$REGION" --with-decryption \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

# Update the webhook URL in baked service files via drop-in overrides
mkdir -p /etc/systemd/system/idle-watchdog.service.d
cat > /etc/systemd/system/idle-watchdog.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

mkdir -p /etc/systemd/system/spot-monitor.service.d
cat > /etc/systemd/system/spot-monitor.service.d/webhook.conf <<EOF
[Service]
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
EOF

# 1. Start ComfyUI
echo "--- Starting ComfyUI ---"
systemctl daemon-reload
systemctl start comfyui

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8188/system_stats > /dev/null 2>&1; then
        echo "ComfyUI ready after ${i}s"
        break
    fi
    sleep 2
done

# 2. Start quick tunnel
echo "--- Starting quick tunnel ---"
cloudflared tunnel --url http://localhost:8188 --no-autoupdate > /tmp/tunnel.log 2>&1 &

# Wait for tunnel URL (grep -oE for portability — no PCRE dependency)
TUNNEL_URL=""
for i in $(seq 1 30); do
    sleep 1
    TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log 2>/dev/null | head -1 || true)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
done

if [ -n "$TUNNEL_URL" ]; then
    echo "Tunnel URL: $TUNNEL_URL"
    aws ssm put-parameter \
        --name "/prismata-3d/tunnel-url/$INSTANCE_ID" \
        --type String \
        --value "$TUNNEL_URL" \
        --overwrite \
        --region "$REGION" || echo "Failed to write tunnel URL to SSM"
else
    echo "WARNING: Tunnel URL not captured after 30s"
fi

# 3. Start monitoring (services are baked into AMI, just start them)
echo "--- Starting monitoring ---"
systemctl start idle-watchdog
systemctl start spot-monitor

echo "=== Boot complete $(date) ==="
```

- [ ] **Step 2: Re-upload user-data to S3 and update launch template**

The launch template's user-data needs updating too. This happens after the AMI is built — the `build-ami.sh` output gives you the commands.

- [ ] **Step 3: Commit**

```bash
git add infra/ec2/user-data.sh
git commit -m "feat: update user-data.sh to start ComfyUI instead of placeholder server"
```

---

## Task 7: Example Hunyuan3D Workflow

> **⚠️ MANUAL GATE:** This task is done interactively after the AMI boots (Task 10).
> It cannot be executed by an agent. Skip to Task 8 during automated execution,
> and return to this task during the end-to-end test (Task 11).

**Files:**
- Create: `infra/workflows/hunyuan3d-image-to-3d.json`

A ComfyUI workflow (API format) for the basic pipeline: load image → Hunyuan3D shape generation → texture painting → save GLB.

- [ ] **Step 1: Export workflow from running ComfyUI**

After the AMI is built and an instance is running (Task 10-11):
1. Open the tunnel URL in browser → ComfyUI loads
2. Load `hy3d_example_01.json` from `custom_nodes/ComfyUI-Hunyuan3DWrapper/example_workflows/`
3. Upload a Prismata sprite (e.g., drone.png) via the image upload node
4. Click "Queue Prompt" — verify it generates a 3D model
5. Use "Save (API Format)" to export the working workflow JSON
6. Save locally to `infra/workflows/hunyuan3d-image-to-3d.json`

- [ ] **Step 2: Commit the workflow**

```bash
git add infra/workflows/hunyuan3d-image-to-3d.json
git commit -m "feat: add Hunyuan3D image-to-3D workflow template for ComfyUI"
```

---

## Task 8: AMI Smoke Test Script

**Files:**
- Create: `infra/ami/test-ami.sh`

Run on the build instance before creating the AMI to verify everything works.

- [ ] **Step 1: Create smoke test**

```bash
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
    if "$@" > /dev/null 2>&1; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
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

# Model weights
check "Shape model present" test -d /opt/comfyui/models/diffusion_models/hunyuan3d
check "Model cache present" test -d /opt/comfyui/models/hunyuan3d-cache

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
        ((PASS++))
        break
    fi
    sleep 2
    if [ "$i" -eq 60 ]; then
        echo "  FAIL: ComfyUI did not respond within 120s"
        ((FAIL++))
    fi
done
systemctl stop comfyui

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Commit**

```bash
git add infra/ami/test-ami.sh
git commit -m "feat: add AMI smoke test script"
```

---

## Task 9: Build AMI + Update Launch Template

**Files:** No new files — runs `build-ami.sh` and AWS CLI commands.

- [ ] **Step 1: Build the AMI**

```bash
bash infra/ami/build-ami.sh
```

This takes ~45-60 minutes (NVIDIA install → reboot → ComfyUI + 20GB model download → smoke test → snapshot) and costs ~$1-3. The script handles SSH ingress rules, reboot, smoke testing, and cleanup automatically. It outputs the new AMI ID on success.

- [ ] **Step 2: Update launch template with new AMI**

Using the AMI ID from the build output:

```bash
aws ec2 create-launch-template-version \
    --launch-template-name prismata-3d-gen \
    --source-version 1 \
    --launch-template-data '{"ImageId":"<NEW_AMI_ID>"}' \
    --region us-east-1

aws ec2 modify-launch-template \
    --launch-template-name prismata-3d-gen \
    --default-version 2 \
    --region us-east-1
```

- [ ] **Step 3: Update user-data in launch template**

The launch template embeds user-data as base64. Update it with the new user-data.sh:

```bash
USER_DATA_B64=$(base64 -w0 infra/ec2/user-data.sh)
aws ec2 create-launch-template-version \
    --launch-template-name prismata-3d-gen \
    --source-version 2 \
    --launch-template-data "{\"UserData\":\"$USER_DATA_B64\"}" \
    --region us-east-1

aws ec2 modify-launch-template \
    --launch-template-name prismata-3d-gen \
    --default-version 3 \
    --region us-east-1
```

---

## Task 10: End-to-End Test

**Files:** None — this is a manual test.

- [ ] **Step 1: Launch via Discord**

In #prismata-ops, type `!start`. The bot should:
1. Launch a spot instance with the new AMI
2. Post "Starting up..." message
3. Post the tunnel URL when ready (~2-3 min)

- [ ] **Step 2: Open ComfyUI**

Open the tunnel URL in a browser. You should see ComfyUI's interface.

- [ ] **Step 3: Load Hunyuan3D workflow**

1. In ComfyUI, load one of the example workflows from `custom_nodes/ComfyUI-Hunyuan3DWrapper/example_workflows/`
2. Upload a Prismata sprite (e.g., drone.png) via the image upload node
3. Click "Queue Prompt"
4. Wait for generation (~30-60 seconds)
5. Download the output GLB

- [ ] **Step 4: Verify idle shutdown**

Leave the instance idle (close browser tab). After ~10 minutes, the watchdog should shut it down and post to Discord.

- [ ] **Step 5: Stop via Discord**

If the instance is still running, type `!stop` to terminate it.

---

## Summary

| Task | What | Estimate |
|------|------|----------|
| 1 | NVIDIA + CUDA install script | 5 min |
| 2 | ComfyUI + Hunyuan3D install script | 10 min |
| 3 | Systemd services (ComfyUI + watchdog + spot monitor) | 5 min |
| 4 | Asset data install script | 5 min |
| 5 | AMI build orchestrator (with reboot + smoke test) | 10 min |
| 6 | Update user-data.sh (simplified, services baked in) | 5 min |
| 7 | Example workflow (**⚠️ manual gate**, post-AMI) | 10 min |
| 8 | Smoke test script | 5 min |
| 9 | Build AMI + update launch template | 45-60 min (mostly waiting) |
| 10 | End-to-end test | 10 min |

**Total active work:** ~1 hour of writing scripts (Tasks 1-8)
**Total wall clock:** ~2 hours (AMI build + model download is slow)
**AWS cost:** ~$1-3 for the build instance + ~$2/month ongoing AMI storage (~50GB snapshot)
