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
intents.reactions = True
bot = commands.Bot(command_prefix="!", intents=intents)


@bot.event
async def on_ready():
    print(f"Bot ready: {bot.user} | Channel: #{DISCORD_CHANNEL_NAME}")


async def _launch_and_wait(ctx, launch_fn, label):
    """Launch an instance and poll for tunnel URL."""
    instance_id = await asyncio.to_thread(launch_fn)
    await ctx.send(f"{label} instance `{instance_id}` launching...")

    import boto3
    ssm = boto3.client("ssm", region_name=AWS_REGION)

    # Phase 1: wait for instance to be running
    ip = None
    for attempt in range(60):  # up to 5 min
        await asyncio.sleep(5)
        instances = await asyncio.to_thread(ec2.get_running)
        for inst in instances:
            if inst["InstanceId"] == instance_id and inst["State"]["Name"] == "running":
                ip = inst.get("PublicIpAddress", "unknown")
                break
        if ip:
            break
    else:
        await ctx.send(f"Instance `{instance_id}` still not ready after 5 min. Check `!status`.")
        return

    await ctx.send(f"Instance `{instance_id}` running at IP `{ip}`. Waiting for tunnel URL...")

    # Phase 2: poll for tunnel URL (up to 3 min — ComfyUI + cloudflared startup)
    for attempt in range(36):
        await asyncio.sleep(5)
        try:
            param = ssm.get_parameter(
                Name=f"/prismata-3d/tunnel-url/{instance_id}")
            tunnel_url = param["Parameter"]["Value"]
            await ctx.send(
                f"**Ready!** Instance `{instance_id}` is up.\n"
                f"[ComfyUI]({tunnel_url})\n"
                f"[Fabrication Terminal]({tunnel_url}/fabricate/index.html)\n"
                f"Auto-shutdown after 10 min idle."
            )
            return
        except Exception:
            pass

    await ctx.send(
        f"Instance `{instance_id}` is running but tunnel URL not found.\n"
        f"ComfyUI may still be starting — try `!status` in a minute.\n"
        f"Auto-shutdown after 10 min idle."
    )


@bot.command()
async def start(ctx: commands.Context, mode: str = "spot"):
    """Launch a GPU instance. Use '!start od' for on-demand."""
    if not is_ops_channel(ctx):
        return

    await ctx.send("Starting up (~2-3 min)...")

    if mode == "od":
        try:
            await _launch_and_wait(ctx, ec2.launch_on_demand, "On-demand")
        except Exception as e:
            await ctx.send(f"Error launching on-demand: {str(e)[:200]}")
        return

    try:
        await _launch_and_wait(ctx, ec2.launch_spot, "Spot")
    except RuntimeError as e:
        if "Maximum" in str(e):
            await ctx.send(f"Cannot start: {e}")
        else:
            raise
    except Exception as e:
        error_msg = str(e)
        if "InsufficientInstanceCapacity" in error_msg or "capacity" in error_msg.lower() or "MaxSpotInstanceCount" in error_msg:
            msg = await ctx.send(
                f"No spot capacity available in {AWS_REGION}.\n"
                f"Launch on-demand instead? (~${ON_DEMAND_PRICE_ESTIMATE:.2f}/hr)\n"
                f"React with \u2705 to confirm."
            )
            await msg.add_reaction("\u2705")
            # Store message ID so reaction handler can find it
            bot._od_fallback_msg = msg.id
            bot._od_fallback_ctx = ctx
        else:
            await ctx.send(f"Error launching instance: {error_msg[:200]}")


@bot.event
async def on_reaction_add(reaction, user):
    """Handle ✅ reaction on on-demand fallback prompt."""
    if user.bot:
        return
    if not hasattr(bot, "_od_fallback_msg"):
        return
    if reaction.message.id != bot._od_fallback_msg:
        return
    if str(reaction.emoji) != "\u2705":
        return

    ctx = bot._od_fallback_ctx
    del bot._od_fallback_msg
    del bot._od_fallback_ctx

    await ctx.send("Launching on-demand instance...")
    try:
        await _launch_and_wait(ctx, ec2.launch_on_demand, "On-demand")
    except Exception as e:
        await ctx.send(f"Error launching on-demand: {str(e)[:200]}")


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

    import boto3
    ssm = boto3.client("ssm", region_name=AWS_REGION)
    for inst in instances:
        cost = ec2.estimate_cost(inst)
        lifecycle = inst.get("InstanceLifecycle", "on-demand")
        await ctx.send(format_cost_estimate(cost, lifecycle))
        # Show tunnel URL if available
        iid = inst["InstanceId"]
        try:
            param = ssm.get_parameter(Name=f"/prismata-3d/tunnel-url/{iid}")
            url = param["Parameter"]["Value"]
            await ctx.send(
                f"[ComfyUI]({url})\n"
                f"[Fabrication Terminal]({url}/fabricate/index.html)"
            )
        except Exception:
            pass


def main():
    if not DISCORD_TOKEN:
        print("ERROR: Set DISCORD_TOKEN environment variable")
        return 1
    bot.run(DISCORD_TOKEN)
    return 0


if __name__ == "__main__":
    exit(main())
