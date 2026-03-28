#!/bin/bash
# infra/ami/build-ami.sh
# Build the Prismata 3D Gen AMI.
#
# This script:
# 1. Launches a temporary g5.xlarge from AWS Deep Learning Base AMI (NVIDIA drivers pre-installed)
# 2. Installs CUDA toolkit + ComfyUI + Hunyuan3D (no reboot needed)
# 3. Runs smoke tests, creates AMI, terminates build instance
#
# Usage: bash infra/ami/build-ami.sh
# Cost: ~$1-3 (g5.xlarge on-demand for ~1-1.5 hours)
#
# WARNING: Resource IDs below are project-specific (Surfinite's AWS account).
# Do not run this without updating them for your own environment.

set -euo pipefail

REGION="us-east-1"
BASE_AMI="ami-049ed450c1d8ab10e"          # Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20260324
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
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":150,"VolumeType":"gp3"}}]' \
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
for f in install-nvidia.sh install-comfyui.sh install-assets.sh install-frontend.sh \
         comfyui.service idle-watchdog.service spot-monitor.service test-ami.sh; do
    $SCP "$SCRIPT_DIR/$f" "ubuntu@$BUILD_IP:/tmp/"
done

# Verify NVIDIA drivers (pre-installed in Deep Learning AMI) + install CUDA toolkit
echo "--- Verifying NVIDIA + installing CUDA toolkit (~5 min) ---"
$SSH "sudo bash /tmp/install-nvidia.sh"

# Install ComfyUI + Hunyuan3D (GPU already available, no reboot needed)
echo "--- Installing ComfyUI + Hunyuan3D (~30-40 min, includes ~20GB model download) ---"
$SSH "sudo bash /tmp/install-comfyui.sh"

echo "--- Installing asset data ---"
$SSH "sudo bash /tmp/install-assets.sh"

echo "--- Installing Fabrication Terminal frontend ---"
$SSH "sudo bash /tmp/install-frontend.sh"

# Install all systemd services (baked into AMI)
echo "--- Installing systemd services ---"
$SSH "sudo cp /tmp/comfyui.service /tmp/idle-watchdog.service /tmp/spot-monitor.service /etc/systemd/system/"
$SSH "sudo systemctl daemon-reload && sudo systemctl enable comfyui"

# Install cloudflared (wait for dpkg lock — unattended-upgrades may be running on fresh Ubuntu)
echo "--- Installing cloudflared ---"
$SSH "sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb && for i in \$(seq 1 30); do sudo dpkg -i /tmp/cloudflared.deb && break; echo 'dpkg locked, waiting 10s...'; sleep 10; done"

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
echo "Estimated AMI storage: \$2/month"
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
