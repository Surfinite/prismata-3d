# Phase 1A: Discord Bot + AWS Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Discord bot that launches/stops AWS GPU spot instances on demand, with Cloudflare Tunnel for secure access, idle auto-shutdown, and spot interruption handling.

**Architecture:** A Python Discord bot on the existing `prismata-data` server (t4g.micro, us-east-1) manages EC2 spot instance lifecycle. On `!start`, it launches a g5.xlarge with a pre-configured launch template, waits for the Cloudflare Tunnel to come up, and posts the URL. The instance self-terminates after 10 min idle. Spot interruptions trigger Discord notifications via IMDSv2 polling on the instance.

**Tech Stack:** Python 3, discord.py, boto3, cloudflared, systemd, bash

**Spec:** `docs/superpowers/specs/2026-03-27-batch-3d-model-generation-pipeline.md`

**Prerequisite:** Phase 0 complete (asset data in S3 at `s3://prismata-3d-models/asset-prep/`)

---

## File Structure

```
infra/
  bot/
    bot.py                 — Discord bot: !start, !stop, !status commands
    ec2_manager.py         — Launch/stop/describe EC2 spot instances
    config.py              — Bot configuration (region, instance type, channel, etc.)
    test_ec2_manager.py    — Tests for EC2 manager (mocked boto3)
    test_bot.py            — Tests for bot command logic
    requirements.txt       — discord.py, boto3
    deploy.sh              — Deploy bot to prismata-data server

  ec2/
    user-data.sh           — EC2 boot script (start services, tunnel, watchdog)
    idle-watchdog.sh        — Monitors activity, shuts down after 10 min idle
    spot-monitor.sh        — Polls IMDSv2 for spot interruption, notifies Discord
    setup-tunnel.sh        — Installs and configures cloudflared

  aws/
    setup-infra.sh         — One-time: create IAM role, security group, launch template
    create-tunnel.sh       — One-time: create Cloudflare tunnel + DNS route
```

### Key decisions:
- Bot and EC2 scripts live in `infra/` (not `tools/`) — separate from the Godot project
- Bot is deployed to prismata-data via SSH + rsync
- Cloudflare tunnel credentials baked into launch template user-data (created once, reused)
- No AMI build yet — Phase 1B handles the GPU instance runtime. This plan uses a stock Ubuntu AMI with user-data that installs a simple test web server to validate the full lifecycle.

---

### Task 1: Bot Configuration and EC2 Manager

**Files:**
- Create: `infra/bot/config.py`
- Create: `infra/bot/ec2_manager.py`
- Create: `infra/bot/test_ec2_manager.py`
- Create: `infra/bot/requirements.txt`

The EC2 manager handles launching spot instances, stopping them, and querying their status. It uses boto3 and is testable with mocked AWS calls.

- [ ] **Step 1: Create requirements.txt**

```
# infra/bot/requirements.txt
discord.py>=2.3,<3
boto3>=1.34
```

- [ ] **Step 2: Create config.py**

```python
# infra/bot/config.py
"""Bot and AWS configuration. Override via environment variables."""
import os

# AWS
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
INSTANCE_TYPE = os.environ.get("INSTANCE_TYPE", "g5.xlarge")
LAUNCH_TEMPLATE_NAME = os.environ.get("LAUNCH_TEMPLATE_NAME", "prismata-3d-gen")
MAX_INSTANCES = int(os.environ.get("MAX_INSTANCES", "2"))
SPOT_MAX_PRICE = os.environ.get("SPOT_MAX_PRICE", "0.80")  # $/hr, safety cap
ON_DEMAND_PRICE_ESTIMATE = 1.006  # g5.xlarge us-east-1 on-demand $/hr

# S3
S3_BUCKET = os.environ.get("S3_BUCKET", "prismata-3d-models")

# Discord
DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "")
DISCORD_CHANNEL_NAME = os.environ.get("DISCORD_CHANNEL_NAME", "prismata-ops")

# Cloudflare
TUNNEL_HOSTNAME = os.environ.get("TUNNEL_HOSTNAME", "prismata-3d.example.com")

# Tags for tracking
INSTANCE_TAG_KEY = "Project"
INSTANCE_TAG_VALUE = "prismata-3d-gen"
```

- [ ] **Step 3: Write failing tests for EC2 manager**

```python
# infra/bot/test_ec2_manager.py
import pytest
from unittest.mock import MagicMock, patch
from ec2_manager import EC2Manager


@pytest.fixture
def mock_ec2():
    with patch("ec2_manager.boto3") as mock_boto3:
        mock_client = MagicMock()
        mock_boto3.client.return_value = mock_client
        manager = EC2Manager(region="us-east-1", launch_template="test-template")
        yield manager, mock_client


def test_launch_spot_instance(mock_ec2):
    manager, client = mock_ec2
    client.run_instances.return_value = {
        "Instances": [{"InstanceId": "i-abc123", "State": {"Name": "pending"}}]
    }
    instance_id = manager.launch_spot()
    assert instance_id == "i-abc123"
    call_args = client.run_instances.call_args
    assert call_args[1]["InstanceMarketOptions"]["MarketType"] == "spot"


def test_launch_on_demand_instance(mock_ec2):
    manager, client = mock_ec2
    client.run_instances.return_value = {
        "Instances": [{"InstanceId": "i-def456", "State": {"Name": "pending"}}]
    }
    instance_id = manager.launch_on_demand()
    assert instance_id == "i-def456"
    call_args = client.run_instances.call_args
    assert "InstanceMarketOptions" not in call_args[1]


def test_stop_instance(mock_ec2):
    manager, client = mock_ec2
    manager.stop("i-abc123")
    client.terminate_instances.assert_called_once_with(InstanceIds=["i-abc123"])


def test_get_running_instances(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [{
                "InstanceId": "i-abc123",
                "State": {"Name": "running"},
                "LaunchTime": "2026-03-27T20:00:00Z",
                "InstanceLifecycle": "spot",
                "PublicIpAddress": "1.2.3.4",
            }]
        }]
    }
    instances = manager.get_running()
    assert len(instances) == 1
    assert instances[0]["InstanceId"] == "i-abc123"


def test_get_running_excludes_terminated(mock_ec2):
    manager, client = mock_ec2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [
                {"InstanceId": "i-abc123", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
                {"InstanceId": "i-dead", "State": {"Name": "terminated"},
                 "LaunchTime": "2026-03-27T19:00:00Z"},
            ]
        }]
    }
    instances = manager.get_running()
    assert len(instances) == 1


def test_launch_respects_max_instances(mock_ec2):
    manager, client = mock_ec2
    manager._max_instances = 2
    client.describe_instances.return_value = {
        "Reservations": [{
            "Instances": [
                {"InstanceId": "i-1", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
                {"InstanceId": "i-2", "State": {"Name": "running"},
                 "LaunchTime": "2026-03-27T20:00:00Z", "InstanceLifecycle": "spot"},
            ]
        }]
    }
    with pytest.raises(RuntimeError, match="Maximum.*instances"):
        manager.launch_spot()
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd infra/bot && pip install -r requirements.txt && python -m pytest test_ec2_manager.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ec2_manager'`

- [ ] **Step 5: Implement EC2 manager**

```python
# infra/bot/ec2_manager.py
"""Manage EC2 spot/on-demand instances for the 3D generation pipeline."""
import boto3
from datetime import datetime, timezone


class EC2Manager:
    def __init__(
        self,
        region: str = "us-east-1",
        launch_template: str = "prismata-3d-gen",
        max_instances: int = 2,
        spot_max_price: str = "0.80",
        tag_key: str = "Project",
        tag_value: str = "prismata-3d-gen",
    ):
        self._client = boto3.client("ec2", region_name=region)
        self._launch_template = launch_template
        self._max_instances = max_instances
        self._spot_max_price = spot_max_price
        self._tag_key = tag_key
        self._tag_value = tag_value

    def _check_capacity(self) -> None:
        running = self.get_running()
        if len(running) >= self._max_instances:
            raise RuntimeError(
                f"Maximum {self._max_instances} instances already running"
            )

    def launch_spot(self) -> str:
        """Launch a spot instance. Returns instance ID."""
        self._check_capacity()
        resp = self._client.run_instances(
            LaunchTemplate={"LaunchTemplateName": self._launch_template},
            MinCount=1,
            MaxCount=1,
            InstanceMarketOptions={
                "MarketType": "spot",
                "SpotOptions": {
                    "MaxPrice": self._spot_max_price,
                    "SpotInstanceType": "one-time",
                    "InstanceInterruptionBehavior": "terminate",
                },
            },
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [{"Key": self._tag_key, "Value": self._tag_value}],
            }],
        )
        return resp["Instances"][0]["InstanceId"]

    def launch_on_demand(self) -> str:
        """Launch an on-demand instance. Returns instance ID."""
        self._check_capacity()
        resp = self._client.run_instances(
            LaunchTemplate={"LaunchTemplateName": self._launch_template},
            MinCount=1,
            MaxCount=1,
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [{"Key": self._tag_key, "Value": self._tag_value}],
            }],
        )
        return resp["Instances"][0]["InstanceId"]

    def stop(self, instance_id: str) -> None:
        """Terminate an instance."""
        self._client.terminate_instances(InstanceIds=[instance_id])

    def get_running(self) -> list[dict]:
        """Get all running/pending instances with our tag."""
        resp = self._client.describe_instances(
            Filters=[
                {"Name": f"tag:{self._tag_key}", "Values": [self._tag_value]},
                {"Name": "instance-state-name", "Values": ["pending", "running"]},
            ]
        )
        instances = []
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                if inst["State"]["Name"] in ("pending", "running"):
                    instances.append(inst)
        return instances

    def estimate_cost(self, instance: dict) -> float:
        """Estimate cost in USD based on uptime. Rough estimate only."""
        launch_time = instance.get("LaunchTime")
        if isinstance(launch_time, str):
            launch_time = datetime.fromisoformat(launch_time.replace("Z", "+00:00"))
        if not launch_time:
            return 0.0
        uptime_hours = (datetime.now(timezone.utc) - launch_time).total_seconds() / 3600
        # Spot is roughly 40% of on-demand for g5.xlarge
        is_spot = instance.get("InstanceLifecycle") == "spot"
        hourly_rate = 0.40 if is_spot else 1.006
        return round(uptime_hours * hourly_rate, 2)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd infra/bot && python -m pytest test_ec2_manager.py -v`
Expected: All 6 tests PASS

- [ ] **Step 7: Commit**

```bash
git add infra/bot/config.py infra/bot/ec2_manager.py infra/bot/test_ec2_manager.py infra/bot/requirements.txt
git commit -m "feat: add EC2 manager for spot/on-demand instance lifecycle"
```

---

### Task 2: Discord Bot Core

**Files:**
- Create: `infra/bot/bot.py`
- Create: `infra/bot/test_bot.py`

The bot responds to `!start`, `!stop`, `!status` in the configured channel. It uses EC2Manager for instance lifecycle and posts status updates.

- [ ] **Step 1: Write failing tests**

```python
# infra/bot/test_bot.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from bot import format_status_message, format_cost_estimate


def test_format_status_no_instances():
    msg = format_status_message([])
    assert "No instances running" in msg


def test_format_status_one_instance():
    instances = [{
        "InstanceId": "i-abc123",
        "State": {"Name": "running"},
        "InstanceLifecycle": "spot",
        "LaunchTime": "2026-03-27T20:00:00Z",
        "PublicIpAddress": "1.2.3.4",
    }]
    msg = format_status_message(instances)
    assert "i-abc123" in msg
    assert "running" in msg
    assert "spot" in msg


def test_format_status_two_instances():
    instances = [
        {"InstanceId": "i-1", "State": {"Name": "running"},
         "InstanceLifecycle": "spot", "LaunchTime": "2026-03-27T20:00:00Z"},
        {"InstanceId": "i-2", "State": {"Name": "pending"},
         "LaunchTime": "2026-03-27T20:30:00Z"},
    ]
    msg = format_status_message(instances)
    assert "i-1" in msg
    assert "i-2" in msg


def test_format_cost_estimate():
    msg = format_cost_estimate(0.42, "spot")
    assert "$0.42" in msg
    msg2 = format_cost_estimate(1.50, "on-demand")
    assert "$1.50" in msg2
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd infra/bot && python -m pytest test_bot.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'bot'`

- [ ] **Step 3: Implement the bot**

```python
# infra/bot/bot.py
"""
Discord bot for managing Prismata 3D generation GPU instances.

Commands:
  !start  — Launch a spot GPU instance
  !stop   — Terminate a running instance
  !status — Show running instances with cost estimates

Environment variables:
  DISCORD_TOKEN — Bot token (required)
  AWS_REGION — AWS region (default: us-east-1)
  DISCORD_CHANNEL_NAME — Channel to respond in (default: prismata-ops)
"""
import os
import asyncio
import discord
from discord.ext import commands
from datetime import datetime, timezone

from ec2_manager import EC2Manager
from config import (
    AWS_REGION, INSTANCE_TYPE, LAUNCH_TEMPLATE_NAME, MAX_INSTANCES,
    SPOT_MAX_PRICE, DISCORD_TOKEN, DISCORD_CHANNEL_NAME,
    TUNNEL_HOSTNAME, ON_DEMAND_PRICE_ESTIMATE, INSTANCE_TAG_KEY, INSTANCE_TAG_VALUE,
)


def format_status_message(instances: list[dict]) -> str:
    """Format instance list into a Discord message."""
    if not instances:
        return "No instances running."

    lines = [f"**{len(instances)} instance(s) running:**"]
    for inst in instances:
        iid = inst["InstanceId"]
        state = inst["State"]["Name"]
        lifecycle = inst.get("InstanceLifecycle", "on-demand")
        ip = inst.get("PublicIpAddress", "pending...")
        launch = inst.get("LaunchTime", "")
        if isinstance(launch, str) and launch:
            try:
                lt = datetime.fromisoformat(launch.replace("Z", "+00:00"))
                uptime = datetime.now(timezone.utc) - lt
                hours = uptime.total_seconds() / 3600
                uptime_str = f"{hours:.1f}h"
            except ValueError:
                uptime_str = "?"
        elif hasattr(launch, "isoformat"):
            uptime = datetime.now(timezone.utc) - launch
            hours = uptime.total_seconds() / 3600
            uptime_str = f"{hours:.1f}h"
        else:
            uptime_str = "?"
        lines.append(f"  `{iid}` — {state} ({lifecycle}) — IP: {ip} — uptime: {uptime_str}")
    return "\n".join(lines)


def format_cost_estimate(cost: float, lifecycle: str) -> str:
    """Format a cost estimate string."""
    return f"Estimated cost so far: **${cost:.2f}** ({lifecycle})"


def is_ops_channel(ctx: commands.Context) -> bool:
    """Check if command is in the configured ops channel."""
    return ctx.channel.name == DISCORD_CHANNEL_NAME


ec2 = EC2Manager(
    region=AWS_REGION,
    launch_template=LAUNCH_TEMPLATE_NAME,
    max_instances=MAX_INSTANCES,
    spot_max_price=SPOT_MAX_PRICE,
    tag_key=INSTANCE_TAG_KEY,
    tag_value=INSTANCE_TAG_VALUE,
)

intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix="!", intents=intents)


@bot.event
async def on_ready():
    print(f"Bot ready: {bot.user} | Channel: #{DISCORD_CHANNEL_NAME}")


@bot.command()
async def start(ctx: commands.Context):
    """Launch a GPU spot instance for 3D model generation."""
    if not is_ops_channel(ctx):
        return

    await ctx.send("Starting up (~2-3 min)...")

    try:
        instance_id = await asyncio.to_thread(ec2.launch_spot)
        await ctx.send(
            f"Spot instance `{instance_id}` launching.\n"
            f"URL will be posted when ready: `https://{TUNNEL_HOSTNAME}`"
        )

        # Poll until running
        for _ in range(60):  # up to 5 min
            await asyncio.sleep(5)
            instances = await asyncio.to_thread(ec2.get_running)
            for inst in instances:
                if inst["InstanceId"] == instance_id and inst["State"]["Name"] == "running":
                    ip = inst.get("PublicIpAddress", "unknown")
                    await ctx.send(
                        f"Ready! Instance `{instance_id}` running at IP `{ip}`\n"
                        f"Open: **https://{TUNNEL_HOSTNAME}**"
                    )
                    return

        await ctx.send(f"Instance `{instance_id}` still not ready after 5 min. Check `!status`.")

    except RuntimeError as e:
        if "Maximum" in str(e):
            await ctx.send(f"Cannot start: {e}")
        else:
            raise
    except Exception as e:
        error_msg = str(e)
        if "InsufficientInstanceCapacity" in error_msg or "capacity" in error_msg.lower():
            await ctx.send(
                f"No spot capacity available in {AWS_REGION}.\n"
                f"Launch on-demand instead? (~${ON_DEMAND_PRICE_ESTIMATE:.2f}/hr)\n"
                f"React with \u2705 to confirm."
            )
            # TODO Phase 2: Add reaction handler for on-demand fallback
        else:
            await ctx.send(f"Error launching instance: {error_msg[:200]}")


@bot.command()
async def stop(ctx: commands.Context):
    """Terminate running GPU instances."""
    if not is_ops_channel(ctx):
        return

    instances = await asyncio.to_thread(ec2.get_running)
    if not instances:
        await ctx.send("No instances running.")
        return

    for inst in instances:
        iid = inst["InstanceId"]
        await asyncio.to_thread(ec2.stop, iid)
        await ctx.send(f"Terminated `{iid}`.")


@bot.command()
async def status(ctx: commands.Context):
    """Show running instances and estimated costs."""
    if not is_ops_channel(ctx):
        return

    instances = await asyncio.to_thread(ec2.get_running)
    await ctx.send(format_status_message(instances))

    for inst in instances:
        cost = ec2.estimate_cost(inst)
        lifecycle = inst.get("InstanceLifecycle", "on-demand")
        await ctx.send(format_cost_estimate(cost, lifecycle))


def main():
    if not DISCORD_TOKEN:
        print("ERROR: Set DISCORD_TOKEN environment variable")
        return 1
    bot.run(DISCORD_TOKEN)
    return 0


if __name__ == "__main__":
    exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd infra/bot && python -m pytest test_bot.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add infra/bot/bot.py infra/bot/test_bot.py
git commit -m "feat: add Discord bot with !start, !stop, !status commands"
```

---

### Task 3: AWS Infrastructure Setup Script

**Files:**
- Create: `infra/aws/setup-infra.sh`

One-time script to create the IAM role, security group, and launch template in us-east-1. Uses a stock Ubuntu 22.04 AMI for now (Phase 1B replaces with GPU AMI).

- [ ] **Step 1: Create the infrastructure setup script**

```bash
#!/bin/bash
# infra/aws/setup-infra.sh
# One-time setup: IAM role, security group, launch template for prismata-3d-gen
#
# Prerequisites:
#   - AWS CLI configured with admin access
#   - Run from the repo root
#
# Usage: bash infra/aws/setup-infra.sh

set -euo pipefail

REGION="us-east-1"
PROJECT="prismata-3d-gen"
INSTANCE_TYPE="g5.xlarge"

echo "=== Prismata 3D Gen — AWS Infrastructure Setup ==="
echo "Region: $REGION"
echo ""

# 1. IAM Role for the EC2 instance
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

# Attach policies: S3 access + SSM for admin
aws iam attach-role-policy \
  --role-name "$PROJECT-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

aws iam attach-role-policy \
  --role-name "$PROJECT-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name "$PROJECT-profile" 2>/dev/null || echo "  Profile already exists"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROJECT-profile" \
  --role-name "$PROJECT-role" 2>/dev/null || echo "  Role already attached"

echo "  IAM role and profile created"

# 2. Security group — no public ingress (Cloudflare Tunnel handles access)
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

# Allow outbound only (default), no inbound rules needed with Cloudflare Tunnel

# 3. Get latest Ubuntu 22.04 AMI (placeholder — Phase 1B replaces with custom GPU AMI)
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

# Read user-data script if it exists, otherwise use a minimal placeholder
if [ -f "infra/ec2/user-data.sh" ]; then
  USER_DATA=$(base64 -w 0 < infra/ec2/user-data.sh)
else
  USER_DATA=$(echo '#!/bin/bash
echo "Prismata 3D Gen instance booted at $(date)" > /tmp/boot.log
' | base64 -w 0)
fi

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
echo ""
echo "Next: Create Cloudflare tunnel (infra/aws/create-tunnel.sh)"
echo "Then: Deploy bot (infra/bot/deploy.sh)"
```

- [ ] **Step 2: Run the script**

Run: `bash infra/aws/setup-infra.sh`
Expected: IAM role, security group, and launch template created. Note the security group ID and AMI ID.

- [ ] **Step 3: Verify**

Run: `aws ec2 describe-launch-templates --launch-template-names prismata-3d-gen --region us-east-1 --query "LaunchTemplates[0].LaunchTemplateName" --output text`
Expected: `prismata-3d-gen`

- [ ] **Step 4: Commit**

```bash
git add infra/aws/setup-infra.sh
git commit -m "feat: add AWS infrastructure setup script (IAM, SG, launch template)"
```

---

### Task 4: Cloudflare Tunnel Setup

**Files:**
- Create: `infra/aws/create-tunnel.sh`
- Create: `infra/ec2/setup-tunnel.sh`

One-time script to create a named Cloudflare Tunnel, and an EC2 boot-time script that starts the tunnel.

**Prerequisites:** You need a domain on Cloudflare (free plan) and a Cloudflare API token with Zone:DNS:Edit and Account:Cloudflare Tunnel:Edit permissions. The user will need to provide these.

- [ ] **Step 1: Create the tunnel creation script**

```bash
#!/bin/bash
# infra/aws/create-tunnel.sh
# One-time: Create a Cloudflare Tunnel for the 3D gen instance.
#
# Prerequisites:
#   - cloudflared installed locally: brew install cloudflared (or equivalent)
#   - Logged in: cloudflared tunnel login
#   - A domain on Cloudflare
#
# Usage: bash infra/aws/create-tunnel.sh <hostname>
# Example: bash infra/aws/create-tunnel.sh prismata-3d.yourdomain.com

set -euo pipefail

HOSTNAME="${1:-}"
TUNNEL_NAME="prismata-3d-gen"

if [ -z "$HOSTNAME" ]; then
  echo "Usage: bash create-tunnel.sh <hostname>"
  echo "Example: bash create-tunnel.sh prismata-3d.yourdomain.com"
  exit 1
fi

echo "=== Creating Cloudflare Tunnel ==="
echo "Tunnel name: $TUNNEL_NAME"
echo "Hostname: $HOSTNAME"
echo ""

# Create the tunnel
cloudflared tunnel create "$TUNNEL_NAME"

# Get the tunnel UUID
TUNNEL_ID=$(cloudflared tunnel list -o json | python3 -c "
import json, sys
tunnels = json.load(sys.stdin)
for t in tunnels:
    if t['name'] == '$TUNNEL_NAME':
        print(t['id'])
        break
")

echo "Tunnel ID: $TUNNEL_ID"

# Route DNS
cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"
echo "DNS route created: $HOSTNAME -> $TUNNEL_NAME"

# The credentials file is at ~/.cloudflared/<TUNNEL_ID>.json
CREDS_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
echo ""
echo "=== IMPORTANT ==="
echo "Credentials file: $CREDS_FILE"
echo "Tunnel ID: $TUNNEL_ID"
echo ""
echo "You need to make these available to EC2 instances."
echo "Options:"
echo "  1. Store in AWS Secrets Manager (recommended)"
echo "  2. Bake into AMI"
echo "  3. Pass via user-data (less secure)"
echo ""
echo "For now, store in SSM Parameter Store:"
echo "  aws ssm put-parameter --name /prismata-3d/tunnel-credentials --type SecureString --value \"\$(cat $CREDS_FILE)\" --region us-east-1"
echo "  aws ssm put-parameter --name /prismata-3d/tunnel-id --type String --value \"$TUNNEL_ID\" --region us-east-1"
echo "  aws ssm put-parameter --name /prismata-3d/tunnel-hostname --type String --value \"$HOSTNAME\" --region us-east-1"
```

- [ ] **Step 2: Create the EC2 tunnel setup script**

```bash
#!/bin/bash
# infra/ec2/setup-tunnel.sh
# Called from user-data.sh on EC2 boot.
# Installs cloudflared, retrieves credentials from SSM, starts the tunnel.

set -euo pipefail

REGION="us-east-1"

echo "[tunnel] Installing cloudflared..."
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb

echo "[tunnel] Retrieving tunnel config from SSM..."
TUNNEL_ID=$(aws ssm get-parameter --name /prismata-3d/tunnel-id --region "$REGION" --query "Parameter.Value" --output text)
TUNNEL_HOSTNAME=$(aws ssm get-parameter --name /prismata-3d/tunnel-hostname --region "$REGION" --query "Parameter.Value" --output text)
TUNNEL_CREDS=$(aws ssm get-parameter --name /prismata-3d/tunnel-credentials --region "$REGION" --with-decryption --query "Parameter.Value" --output text)

echo "[tunnel] Configuring cloudflared..."
mkdir -p /etc/cloudflared

echo "$TUNNEL_CREDS" > "/etc/cloudflared/$TUNNEL_ID.json"

cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $TUNNEL_HOSTNAME
    service: http://localhost:8188
  - service: http_status:404
EOF

echo "[tunnel] Starting cloudflared service..."
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared

echo "[tunnel] Tunnel active: https://$TUNNEL_HOSTNAME"
```

- [ ] **Step 3: Commit**

```bash
git add infra/aws/create-tunnel.sh infra/ec2/setup-tunnel.sh
git commit -m "feat: add Cloudflare Tunnel creation and EC2 setup scripts"
```

---

### Task 5: EC2 User-Data, Idle Watchdog, and Spot Monitor

**Files:**
- Create: `infra/ec2/user-data.sh`
- Create: `infra/ec2/idle-watchdog.sh`
- Create: `infra/ec2/spot-monitor.sh`

These run on the EC2 instance at boot time. user-data.sh is the entrypoint, it calls setup-tunnel.sh and starts the watchdog and spot monitor.

- [ ] **Step 1: Create the idle watchdog**

```bash
#!/bin/bash
# infra/ec2/idle-watchdog.sh
# Monitors activity and shuts down the instance after 10 minutes of inactivity.
#
# Activity signals:
#   - Active WebSocket connections to port 8188 (ComfyUI)
#   - Recent HTTP requests (last modified time of access log)
#   - Running generation jobs (check for python/comfyui processes using GPU)
#
# Runs as a systemd service. Checks every 60 seconds.

IDLE_THRESHOLD=600  # 10 minutes in seconds
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LAST_ACTIVITY_FILE="/tmp/last_activity"

# Initialize activity timestamp
date +%s > "$LAST_ACTIVITY_FILE"

log() { echo "[watchdog $(date +%H:%M:%S)] $*"; }

check_activity() {
    # Check for active WebSocket connections on port 8188
    if ss -tn state established '( dport = :8188 or sport = :8188 )' | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi

    # Check for GPU-using processes (generation running)
    if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi

    return 1
}

notify_discord() {
    local msg="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -H "Content-Type: application/json" \
            -d "{\"content\": \"$msg\"}" \
            "$DISCORD_WEBHOOK_URL" || true
    fi
}

while true; do
    sleep 60

    check_activity || true

    last=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    idle=$((now - last))

    if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
        log "Idle for ${idle}s (threshold: ${IDLE_THRESHOLD}s). Shutting down..."
        notify_discord "Shutting down after 10 min idle."

        # Grace period — wait 60s in case someone reacts
        sleep 60

        # Re-check in case activity resumed during grace period
        check_activity && { log "Activity detected during grace period, continuing."; continue; }

        # Sync any outputs to S3 before shutdown
        aws s3 sync /opt/prismata-3d/output/ "s3://prismata-3d-models/models/" --region us-east-1 2>/dev/null || true

        log "Shutting down now."
        sudo shutdown -h now
        exit 0
    fi

    log "Idle: ${idle}s / ${IDLE_THRESHOLD}s"
done
```

- [ ] **Step 2: Create the spot interruption monitor**

```bash
#!/bin/bash
# infra/ec2/spot-monitor.sh
# Polls IMDSv2 every 5 seconds for spot termination notice.
# On interruption: saves state to S3, notifies Discord.

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

log() { echo "[spot-monitor $(date +%H:%M:%S)] $*"; }

notify_discord() {
    local msg="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -H "Content-Type: application/json" \
            -d "{\"content\": \"$msg\"}" \
            "$DISCORD_WEBHOOK_URL" || true
    fi
}

# Get IMDSv2 token
get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null
}

TOKEN=$(get_token)

while true; do
    sleep 5

    # Refresh token every 4 minutes
    if [ $((SECONDS % 240)) -lt 6 ]; then
        TOKEN=$(get_token)
    fi

    # Check for spot interruption
    ACTION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/spot/instance-action" 2>/dev/null)

    if echo "$ACTION" | grep -q "terminate\|stop"; then
        log "SPOT INTERRUPTION DETECTED: $ACTION"
        notify_discord "⚠️ Spot instance being reclaimed by AWS! Saving work to S3..."

        # Save any in-progress outputs
        aws s3 sync /opt/prismata-3d/output/ "s3://prismata-3d-models/models/" --region us-east-1 2>/dev/null || true

        # Save job queue state
        if [ -f /opt/prismata-3d/queue_state.json ]; then
            aws s3 cp /opt/prismata-3d/queue_state.json "s3://prismata-3d-models/state/queue_state.json" --region us-east-1 2>/dev/null || true
        fi

        notify_discord "Work saved to S3. Instance will terminate shortly."
        log "Cleanup complete. Waiting for termination."

        # Wait for AWS to terminate us (up to 2 min from notice)
        sleep 120
        exit 0
    fi
done
```

- [ ] **Step 3: Create the user-data boot script**

```bash
#!/bin/bash
# infra/ec2/user-data.sh
# EC2 instance boot script. Runs as root on first boot.
#
# Responsibilities:
#   1. Set up Cloudflare Tunnel
#   2. Start idle watchdog
#   3. Start spot interruption monitor
#   4. Start the application (ComfyUI — handled by Phase 1B)

set -euo pipefail

exec > /var/log/user-data.log 2>&1
echo "=== Prismata 3D Gen — Instance Boot $(date) ==="

REGION="us-east-1"
export AWS_DEFAULT_REGION="$REGION"

# Retrieve Discord webhook URL from SSM (for watchdog/spot-monitor notifications)
export DISCORD_WEBHOOK_URL=$(aws ssm get-parameter \
    --name /prismata-3d/discord-webhook-url \
    --region "$REGION" \
    --with-decryption \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

# 1. Set up Cloudflare Tunnel
echo "--- Setting up Cloudflare Tunnel ---"
if [ -f /opt/prismata-3d/setup-tunnel.sh ]; then
    bash /opt/prismata-3d/setup-tunnel.sh
else
    echo "WARNING: setup-tunnel.sh not found, skipping tunnel setup"
fi

# 2. Start idle watchdog
echo "--- Starting idle watchdog ---"
cp /opt/prismata-3d/idle-watchdog.sh /usr/local/bin/idle-watchdog.sh
chmod +x /usr/local/bin/idle-watchdog.sh

cat > /etc/systemd/system/idle-watchdog.service <<EOF
[Unit]
Description=Prismata 3D Gen Idle Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/idle-watchdog.sh
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable idle-watchdog
systemctl start idle-watchdog

# 3. Start spot interruption monitor
echo "--- Starting spot monitor ---"
cp /opt/prismata-3d/spot-monitor.sh /usr/local/bin/spot-monitor.sh
chmod +x /usr/local/bin/spot-monitor.sh

cat > /etc/systemd/system/spot-monitor.service <<EOF
[Unit]
Description=Prismata 3D Gen Spot Interruption Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/spot-monitor.sh
Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable spot-monitor
systemctl start spot-monitor

# 4. Application startup (Phase 1B will add ComfyUI startup here)
echo "--- Application ---"
echo "Phase 1B: ComfyUI startup will be added here"

# For now, start a simple HTTP server on port 8188 as a placeholder
mkdir -p /opt/prismata-3d/output
python3 -m http.server 8188 --directory /opt/prismata-3d/output &

echo "=== Boot complete $(date) ==="
```

- [ ] **Step 4: Commit**

```bash
git add infra/ec2/user-data.sh infra/ec2/idle-watchdog.sh infra/ec2/spot-monitor.sh
git commit -m "feat: add EC2 user-data, idle watchdog, and spot monitor scripts"
```

---

### Task 6: Bot Deployment Script

**Files:**
- Create: `infra/bot/deploy.sh`

Deploys the bot to the prismata-data server via SSH + rsync.

- [ ] **Step 1: Create deploy script**

```bash
#!/bin/bash
# infra/bot/deploy.sh
# Deploy the Discord bot to prismata-data server.
#
# Prerequisites:
#   - SSH access to prismata-data (t4g.micro, us-east-1)
#   - DISCORD_TOKEN stored in SSM Parameter Store or set on the server
#
# Usage: bash infra/bot/deploy.sh <ssh-host>
# Example: bash infra/bot/deploy.sh ubuntu@prismata-data-ip

set -euo pipefail

SSH_HOST="${1:-}"

if [ -z "$SSH_HOST" ]; then
    echo "Usage: bash deploy.sh <ssh-host>"
    echo "Example: bash deploy.sh ubuntu@1.2.3.4"
    exit 1
fi

REMOTE_DIR="/opt/prismata-3d-bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Prismata 3D Bot ==="
echo "Host: $SSH_HOST"
echo "Remote dir: $REMOTE_DIR"
echo ""

# Create remote directory
ssh "$SSH_HOST" "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"

# Sync bot files
rsync -avz --delete \
    "$SCRIPT_DIR/bot.py" \
    "$SCRIPT_DIR/ec2_manager.py" \
    "$SCRIPT_DIR/config.py" \
    "$SCRIPT_DIR/requirements.txt" \
    "$SSH_HOST:$REMOTE_DIR/"

# Install dependencies
ssh "$SSH_HOST" "cd $REMOTE_DIR && pip3 install -r requirements.txt"

# Create systemd service
ssh "$SSH_HOST" "sudo tee /etc/systemd/system/prismata-3d-bot.service > /dev/null <<'EOF'
[Unit]
Description=Prismata 3D Generation Discord Bot
After=network.target

[Service]
Type=simple
User=$(ssh $SSH_HOST whoami)
WorkingDirectory=$REMOTE_DIR
ExecStart=/usr/bin/python3 $REMOTE_DIR/bot.py
Environment=DISCORD_TOKEN=\${DISCORD_TOKEN}
Environment=AWS_REGION=us-east-1
EnvironmentFile=-/etc/prismata-3d-bot.env
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Next steps on the server:"
echo "  1. Create /etc/prismata-3d-bot.env with:"
echo "     DISCORD_TOKEN=your_bot_token_here"
echo "  2. Start the bot:"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable prismata-3d-bot"
echo "     sudo systemctl start prismata-3d-bot"
echo "  3. Check logs:"
echo "     journalctl -u prismata-3d-bot -f"
```

- [ ] **Step 2: Commit**

```bash
git add infra/bot/deploy.sh
git commit -m "feat: add bot deployment script for prismata-data server"
```

---

### Task 7: End-to-End Integration Test

This is a manual verification task. No code to write — just run the full lifecycle to verify everything connects.

- [ ] **Step 1: Pre-flight checklist**

Verify these exist:
- `aws ec2 describe-launch-templates --launch-template-names prismata-3d-gen --region us-east-1`
- `aws ssm get-parameter --name /prismata-3d/tunnel-id --region us-east-1` (if tunnel created)
- `aws s3 ls s3://prismata-3d-models/asset-prep/manifest.json --region us-east-1`

- [ ] **Step 2: Test EC2 launch manually**

```bash
# Launch a test spot instance
aws ec2 run-instances \
  --launch-template LaunchTemplateName=prismata-3d-gen \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"MaxPrice":"0.80","SpotInstanceType":"one-time"}}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=prismata-3d-gen}]' \
  --region us-east-1 \
  --query "Instances[0].InstanceId" --output text
```

Note the instance ID, wait for it to be running, then verify user-data ran:
```bash
# Check instance status
aws ec2 describe-instances --instance-ids <INSTANCE_ID> --region us-east-1 \
  --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress]" --output text

# If tunnel is set up, try accessing https://your-hostname
# Otherwise, check via SSM Session Manager
```

- [ ] **Step 3: Terminate the test instance**

```bash
aws ec2 terminate-instances --instance-ids <INSTANCE_ID> --region us-east-1
```

- [ ] **Step 4: Test the bot locally (dry run)**

```bash
cd infra/bot
DISCORD_TOKEN=test AWS_REGION=us-east-1 python -c "
from ec2_manager import EC2Manager
from bot import format_status_message
print('EC2Manager imports OK')
print('Bot imports OK')
print(format_status_message([]))
print('All good!')
"
```

Expected: `No instances running.` and `All good!`

- [ ] **Step 5: Final commit — update launch template with real user-data**

```bash
# Re-encode user-data with EC2 scripts included
# (This step will be more meaningful once Phase 1B adds the AMI)
git add -A infra/
git commit -m "chore: finalize Phase 1A infrastructure scripts"
```
