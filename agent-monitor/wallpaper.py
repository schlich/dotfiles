#!/usr/bin/env python3
"""Compact live agent-usage and CI monitor for a Kitty background panel."""

from __future__ import annotations

import curses
import json
import os
import subprocess
import time
from datetime import datetime


CI_REPO = os.environ.get("FIELDNOTES_CI_REPO", "schlich/dotfiles")
POLL_SECONDS = 30


def command_json(
    command: list[str], timeout: int = 12
) -> tuple[object | None, str | None]:
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout
        )
    except FileNotFoundError:
        return None, f"{command[0]} is not installed"
    except subprocess.TimeoutExpired:
        return None, f"{command[0]} timed out"
    if result.returncode:
        detail = result.stderr.strip().splitlines()
        return None, detail[
            -1
        ] if detail else f"{command[0]} exited with {result.returncode}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"{command[0]} returned invalid JSON"


def fetch_usage() -> tuple[list[dict], str | None]:
    data, error = command_json(["ai-usagebar", "usage", "--json"])
    if error:
        return [], error
    entries = data.get("entries", []) if isinstance(data, dict) else []
    rows = []
    for entry in entries:
        if entry.get("status") != "ready":
            continue
        for metric in entry.get("metrics", []):
            percent = metric.get("percent")
            if percent is None:
                continue
            rows.append(
                {
                    "provider": entry.get("display_name", entry.get("id", "Provider")),
                    "label": metric.get("label", "Usage"),
                    "value": metric.get("value", "—"),
                    "percent": max(0, min(100, int(percent))),
                    "reset": metric.get("reset_at"),
                }
            )
    return rows, None


def fetch_runs() -> tuple[list[dict], str | None]:
    data, error = command_json(
        [
            "gh",
            "run",
            "list",
            "--repo",
            CI_REPO,
            "--limit",
            "6",
            "--json",
            "workflowName,displayTitle,status,conclusion,createdAt,headBranch,url",
        ]
    )
    return (data if isinstance(data, list) else []), error


def shorten(value: object, width: int) -> str:
    text = str(value or "—")
    return text if len(text) <= width else text[: max(0, width - 1)] + "…"


def init_colors() -> dict[str, int]:
    curses.start_color()
    curses.use_default_colors()
    colors = {
        "normal": curses.color_pair(1),
        "muted": curses.color_pair(2),
        "mint": curses.color_pair(3),
        "lime": curses.color_pair(4),
        "amber": curses.color_pair(5),
        "coral": curses.color_pair(6),
        "purple": curses.color_pair(7),
    }
    curses.init_pair(1, curses.COLOR_WHITE, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_CYAN, -1)
    curses.init_pair(4, curses.COLOR_YELLOW, -1)
    curses.init_pair(5, curses.COLOR_YELLOW, -1)
    curses.init_pair(6, curses.COLOR_RED, -1)
    curses.init_pair(7, curses.COLOR_MAGENTA, -1)
    return colors


def put(
    screen: curses.window, y: int, x: int, text: str, color: int, width: int
) -> None:
    height, columns = screen.getmaxyx()
    if y < 0 or y >= height or x >= columns:
        return
    try:
        screen.addnstr(
            y, max(0, x), text, max(0, min(width, columns - max(0, x) - 1)), color
        )
    except curses.error:
        pass


def progress(percent: int, width: int) -> str:
    filled = max(0, min(width, round(width * percent / 100)))
    return "█" * filled + "░" * (width - filled)


def reset_label(value: object) -> str:
    if not value:
        return ""
    try:
        reset = datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone()
        delta = int((reset - datetime.now().astimezone()).total_seconds() / 60)
        if delta <= 0:
            return "resetting"
        return (
            f"resets in {delta // 60}h {delta % 60:02d}m"
            if delta >= 60
            else f"resets in {delta}m"
        )
    except (ValueError, TypeError):
        return ""


def draw_panel(
    screen: curses.window,
    x: int,
    y: int,
    width: int,
    title: str,
    colors: dict[str, int],
) -> None:
    put(screen, y, x, "┌" + "─" * max(0, width - 2) + "┐", colors["muted"], width)
    put(screen, y + 1, x, "│", colors["muted"], 1)
    put(screen, y + 1, x + 2, title, colors["lime"], width - 4)
    put(screen, y + 1, x + width - 1, "│", colors["muted"], 1)
    put(screen, y + 2, x, "├" + "─" * max(0, width - 2) + "┤", colors["muted"], width)


def draw(
    screen: curses.window,
    usage: list[dict],
    usage_error: str | None,
    runs: list[dict],
    ci_error: str | None,
    colors: dict[str, int],
) -> None:
    screen.erase()
    height, width = screen.getmaxyx()
    now = datetime.now().astimezone().strftime("%a %d %b  %H:%M:%S")
    put(screen, 0, 2, "FIELDNOTES  /  AGENT MONITOR", colors["lime"], width - 4)
    put(screen, 0, max(2, width - len(now) - 3), now, colors["muted"], len(now))
    put(screen, 1, 2, "AI USAGE  +  CONTINUOUS INTEGRATION", colors["muted"], width - 4)

    gap = 2
    inner_width = max(20, width - 4)
    left_width = max(20, (inner_width - gap) // 2)
    right_width = max(20, inner_width - left_width - gap)
    left_x, right_x = 2, 2 + left_width + gap
    panel_y = 3
    draw_panel(screen, left_x, panel_y, left_width, "PROVIDER WINDOWS", colors)
    draw_panel(
        screen, right_x, panel_y, right_width, f"RECENT CI  /  {CI_REPO}", colors
    )

    body_y = panel_y + 3
    visible_rows = max(1, height - body_y - 3)
    if usage_error:
        put(
            screen,
            body_y,
            left_x + 2,
            "○  Usage data unavailable",
            colors["amber"],
            left_width - 4,
        )
        put(
            screen,
            body_y + 1,
            left_x + 2,
            shorten(usage_error, left_width - 4),
            colors["muted"],
            left_width - 4,
        )
        put(
            screen,
            body_y + 3,
            left_x + 2,
            "Check provider sign-in on this host.",
            colors["muted"],
            left_width - 4,
        )
    elif not usage:
        put(
            screen,
            body_y,
            left_x + 2,
            "No active provider windows reported.",
            colors["muted"],
            left_width - 4,
        )
    else:
        row_y = body_y
        for item in usage[:visible_rows]:
            percent = item["percent"]
            color = (
                colors["coral"]
                if percent >= 90
                else colors["amber"]
                if percent >= 75
                else colors["mint"]
            )
            label = shorten(f"{item['provider']}  /  {item['label']}", left_width - 19)
            put(screen, row_y, left_x + 2, label, colors["normal"], left_width - 4)
            put(screen, row_y, left_x + left_width - 7, f"{percent:>3}%", color, 5)
            bar_width = max(8, left_width - 17)
            put(
                screen,
                row_y + 1,
                left_x + 2,
                progress(percent, bar_width),
                color,
                bar_width,
            )
            details = shorten(
                f"{item['value']} used   {reset_label(item['reset'])}", left_width - 4
            )
            put(screen, row_y + 2, left_x + 2, details, colors["muted"], left_width - 4)
            row_y += 4

    if ci_error:
        put(
            screen,
            body_y,
            right_x + 2,
            "○  CI data unavailable",
            colors["amber"],
            right_width - 4,
        )
        put(
            screen,
            body_y + 1,
            right_x + 2,
            shorten(ci_error, right_width - 4),
            colors["muted"],
            right_width - 4,
        )
        put(
            screen,
            body_y + 3,
            right_x + 2,
            "Authenticate gh on this host to connect.",
            colors["muted"],
            right_width - 4,
        )
    elif not runs:
        put(
            screen,
            body_y,
            right_x + 2,
            "No recent workflow runs.",
            colors["muted"],
            right_width - 4,
        )
    else:
        label_width = max(10, right_width - 23)
        for index, run in enumerate(runs[:visible_rows]):
            row_y = body_y + index * 2
            conclusion = run.get("conclusion") or run.get("status", "unknown")
            state = str(conclusion).lower()
            color = (
                colors["mint"]
                if state in ("success", "completed")
                else colors["coral"]
                if state in ("failure", "cancelled", "timed_out")
                else colors["amber"]
            )
            label = shorten(
                run.get("workflowName") or run.get("displayTitle"), label_width
            )
            branch = shorten(run.get("headBranch", ""), 16)
            put(screen, row_y, right_x + 2, label, colors["normal"], label_width)
            put(screen, row_y, right_x + right_width - 9, state.upper(), color, 7)
            put(
                screen,
                row_y + 1,
                right_x + 2,
                f"↳ {branch}",
                colors["muted"],
                label_width,
            )

    divider_y = min(height - 2, max(body_y + 7, height - 3))
    put(screen, divider_y, 2, "─" * max(0, width - 4), colors["muted"], width - 4)
    put(screen, divider_y + 1, 2, "POLLING EVERY 30s", colors["muted"], 20)
    put(
        screen, divider_y + 1, 23, f"AI USAGE  {len(usage)} windows", colors["mint"], 24
    )
    put(screen, divider_y + 1, 48, f"CI  {len(runs)} runs", colors["mint"], 18)
    screen.refresh()


def main(screen: curses.window) -> None:
    curses.curs_set(0)
    screen.nodelay(True)
    colors = init_colors()
    last_poll = 0.0
    usage: list[dict] = []
    runs: list[dict] = []
    usage_error: str | None = None
    ci_error: str | None = None
    while True:
        key = screen.getch()
        if key in (ord("q"), ord("Q")):
            return
        if key == curses.KEY_RESIZE:
            last_poll = 0
        if time.monotonic() - last_poll >= POLL_SECONDS:
            usage, usage_error = fetch_usage()
            runs, ci_error = fetch_runs()
            last_poll = time.monotonic()
        draw(screen, usage, usage_error, runs, ci_error, colors)
        time.sleep(0.5)


if __name__ == "__main__":
    curses.wrapper(main)
