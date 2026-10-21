"""discord-digest: read new Discord messages, triage them, render the dashboard."""

import argparse
import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import anthropic

from . import config as config_mod
from .dashboard import render
from .discord import DiscordClient, DiscordError, Unreadable, snowflake_at
from .store import Store
from .triage import Triager


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def discord_client(cfg: config_mod.Config) -> DiscordClient:
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        sys.exit("DISCORD_TOKEN is not set. Store it with `secretspec set DISCORD_TOKEN` and run through `secretspec run`.")
    return DiscordClient(token, cfg.request_pace_seconds)


def sync_channels(cfg, discord: DiscordClient, store: Store):
    """Records every server and readable channel you're in, and yields the
    ones the config selects as (guild, channel) pairs."""
    for guild in discord.guilds():
        store.upsert_guild(guild)
        if not cfg.channels.wants_guild(guild.id, guild.name):
            continue
        try:
            channels = discord.channels(guild.id)
        except Unreadable:
            log(f"  skip server {guild.name}: channel list unavailable")
            continue
        for channel in channels:
            store.upsert_channel(channel)
            if cfg.channels.wants_channel(channel.id, channel.name, guild.name):
                yield guild, channel


def cmd_run(cfg, args) -> int:
    discord = discord_client(cfg)
    store = Store(cfg.db_path)
    interests = cfg.interests_file.read_text() if cfg.interests_file.exists() else ""
    if not interests:
        log(f"warning: no interests file at {cfg.interests_file}; triage can only judge releases and discussion")
    triager = Triager(interests, cfg.triage_model, cfg.overview_model)

    run_id = store.start_run()
    start_from = snowflake_at(datetime.now(UTC) - timedelta(hours=cfg.first_run_hours))
    stats = {"channels": 0, "messages": 0, "findings": 0, "failed": 0, "unreadable": 0}

    for guild, channel in sync_channels(cfg, discord, store):
        if not store.readable(channel.id):
            continue
        after = store.cursor(channel.id) or start_from
        label = f"{guild.name} / #{channel.name}"
        try:
            messages = discord.messages_after(channel.id, after, cfg.max_messages_per_channel)
        except Unreadable:
            store.mark_unreadable(channel.id)
            stats["unreadable"] += 1
            continue
        stats["channels"] += 1
        if not messages:
            continue
        try:
            findings = triager.triage(guild.name, channel, messages)
        except anthropic.APIError as e:
            # Leave the cursor where it was so the next run retries.
            log(f"  ✗ {label}: triage failed ({type(e).__name__}: {e})")
            stats["failed"] += 1
            continue
        store.record_channel(run_id, channel.id, messages[-1].id, findings)
        stats["messages"] += len(messages)
        stats["findings"] += len(findings)
        log(f"  {label}: {len(messages)} messages → {len(findings)} findings")

    overview = None
    kept = [f for f in store.run_findings(run_id) if f["score"] >= cfg.min_score]
    try:
        overview = triager.overview(kept)
    except anthropic.APIError as e:
        log(f"  ✗ overview failed ({type(e).__name__}: {e})")
    store.finish_run(run_id, overview, stats)

    out = render(store.recent_runs(cfg.keep_days), store.recent_findings(cfg.keep_days), cfg.min_score, cfg.dashboard_path)
    log(
        f"done: {stats['channels']} channels, {stats['messages']} messages, {stats['findings']} findings"
        f" ({stats['failed']} failed, {stats['unreadable']} unreadable) → {out}"
    )
    return 1 if stats["failed"] and not stats["messages"] else 0


def cmd_channels(cfg, args) -> int:
    """Lists the channels a run would read, so you can tune config.toml."""
    discord = discord_client(cfg)
    store = Store(cfg.db_path)
    selected = list(sync_channels(cfg, discord, store))
    for guild, channel in selected:
        print(f"{guild.name}\t#{channel.name}\t{channel.kind}\t{channel.id}")
    log(f"{len(selected)} channels selected")
    return 0


def cmd_render(cfg, args) -> int:
    store = Store(cfg.db_path)
    out = render(store.recent_runs(cfg.keep_days), store.recent_findings(cfg.keep_days), cfg.min_score, cfg.dashboard_path)
    log(f"rendered {out}")
    return 0


def cmd_check(cfg, args) -> int:
    discord = discord_client(cfg)
    log(f"Discord token works: signed in as {discord.me()}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="discord-digest", description=__doc__)
    parser.add_argument("--config", type=Path, help="config.toml (default: $DISCORD_DIGEST_CONFIG or ./config.toml)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="read new messages, triage them, and render the dashboard")
    sub.add_parser("channels", help="list the channels a run would read")
    sub.add_parser("render", help="re-render the dashboard from stored findings")
    sub.add_parser("check", help="check that the Discord token works")
    args = parser.parse_args(argv)

    cfg = config_mod.load(args.config)
    try:
        return {"run": cmd_run, "channels": cmd_channels, "render": cmd_render, "check": cmd_check}[args.cmd](cfg, args)
    except DiscordError as e:
        log(f"error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
