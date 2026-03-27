#!/bin/bash
# infra/aws/setup-infra.sh
# One-time setup: IAM role, security group, launch template for prismata-3d-gen
#
# Prerequisites:
#   - AWS CLI configured with admin access
#
# Usage: bash infra/aws/setup-infra.sh

set -euo pipefail

REGION="us-east-1"
PROJECT="prismata-3d-gen"
INSTANCE_TYPE="g5.xlarge"

echo "=== Prismata 3D Gen — AWS Infrastructure Setup ==="
echo "Region: $REGION"
echo ""

# 1. IAM Role
echo "--- Creating IAM role ---"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name "$PROJECT-role" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --region "$REGION" 2>/dev/null || echo "  Role already exists"

aws iam attach-role-policy \
  --role-name "$PROJECT-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

aws iam attach-role-policy \
  --role-name "$PROJECT-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

aws iam create-instance-profile \
  --instance-profile-name "$PROJECT-profile" 2>/dev/null || echo "  Profile already exists"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROJECT-profile" \
  --role-name "$PROJECT-role" 2>/dev/null || echo "  Role already attached"

echo "  IAM role and profile created"

# 2. Security group — no public ingress
echo "--- Creating security group ---"
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=is-default,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name "$PROJECT-sg" \
  --description "Prismata 3D gen - no public ingress (Cloudflare Tunnel)" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query "GroupId" --output text 2>/dev/null) || \
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$PROJECT-sg" \
  --region "$REGION" \
  --query "SecurityGroups[0].GroupId" --output text)

echo "  Security group: $SG_ID"

# 3. Get latest Ubuntu 22.04 AMI (placeholder)
echo "--- Finding Ubuntu AMI ---"
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query "sort_by(Images,&CreationDate)[-1].ImageId" \
  --output text)
echo "  AMI: $AMI_ID (Ubuntu 22.04 placeholder)"

# 4. Create launch template
echo "--- Creating launch template ---"

USER_DATA=$(echo '#!/bin/bash
echo "Prismata 3D Gen instance booted at $(date)" > /tmp/boot.log
' | base64 -w 0)

aws ec2 create-launch-template \
  --launch-template-name "$PROJECT" \
  --region "$REGION" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"IamInstanceProfile\": {\"Name\": \"$PROJECT-profile\"},
    \"SecurityGroupIds\": [\"$SG_ID\"],
    \"UserData\": \"$USER_DATA\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Project\", \"Value\": \"$PROJECT\"}]
    }],
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/sda1\",
      \"Ebs\": {\"VolumeSize\": 100, \"VolumeType\": \"gp3\"}
    }]
  }" 2>/dev/null && echo "  Launch template created" || echo "  Launch template already exists"

echo ""
echo "=== Setup complete ==="
echo "Launch template: $PROJECT"
echo "Security group:  $SG_ID"
echo "IAM role:        $PROJECT-role"
echo "AMI:             $AMI_ID (placeholder)"
