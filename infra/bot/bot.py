"""
Discord bot for managing Prismata 3D generation GPU instances.

Commands:
  !start  — Launch a spot GPU instance
  !stop   — Terminate a running instance
  !status — Show running instances with cost estimates

Environment variables:
  DISCORD_TOKEN — Bot token (required)
  AWS_REGION — AWS region (default: us-east-1)
"""
import os
import asyncio
import discord
from discord.ext import commands
from datetime import datetime, timezone

from ec2_manager import EC2Manager
from config import (
    AWS_REGION, LAUNCH_TEMPLATE_NAME, MAX_INSTANCES,
    SPOT_MAX_PRICE, DISCORD_TOKEN, DISCORD_CHANNEL_NAME,
    ON_DEMAND_PRICE_ESTIMATE, INSTANCE_TAG_KEY, INSTANCE_TAG_VALUE,
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
        launch = inst.get("LaunchTime")
        if isinstance(launch, datetime):
            uptime = datetime.now(timezone.utc) - launch
            hours = uptime.total_seconds() / 3600
            uptime_str = f"{hours:.1f}h"
        elif isinstance(launch, str) and launch:
            try:
                lt = datetime.fromisoformat(launch.replace("Z", "+00:00"))
                hours = (datetime.now(timezone.utc) - lt).total_seconds() / 3600
                uptime_str = f"{hours:.1f}h"
            except ValueError:
                uptime_str = "?"
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
        await ctx.send(f"Spot instance `{instance_id}` launching...")

        # Poll until running, then check for tunnel URL
        for attempt in range(60):  # up to 5 min
            await asyncio.sleep(5)
            instances = await asyncio.to_thread(ec2.get_running)
            for inst in instances:
                if inst["InstanceId"] == instance_id and inst["State"]["Name"] == "running":
                    ip = inst.get("PublicIpAddress", "unknown")
                    # Try to read tunnel URL from SSM
                    try:
                        import boto3
                        ssm = boto3.client("ssm", region_name=AWS_REGION)
                        param = ssm.get_parameter(
                            Name=f"/prismata-3d/tunnel-url/{instance_id}")
                        tunnel_url = param["Parameter"]["Value"]
                        await ctx.send(
                            f"Ready! Instance `{instance_id}` running.\n"
                            f"Open: **{tunnel_url}**"
                        )
                    except Exception:
                        await ctx.send(
                            f"Instance `{instance_id}` running at IP `{ip}`.\n"
                            f"Tunnel URL not yet available — check `!status` in a minute."
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
