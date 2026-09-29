#!/usr/bin/env python3
"""Compact live agent-usage and CI monitor for a Kitty background panel."""

from __future__ import annotations

import base64
import curses
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime


CI_REPO = os.environ.get("FIELDNOTES_CI_REPO", "schlich/dotfiles")
# Topics are published as `jj-*` branches on the Tangled knot and wait there
# until `ci land` delivers them to main.
TANGLED_KNOT = os.environ.get("FIELDNOTES_TANGLED_KNOT", "https://knot1.tangled.sh")
TANGLED_REPO_DID = os.environ.get(
    "FIELDNOTES_TANGLED_REPO_DID", "did:plc:3ta3pjip7mu36b7dnznhoyri"
)
# A published topic that has waited this long to land is highlighted.
TOPIC_STALE_DAYS = 2
POLL_SECONDS = 30
# Other hosts push one `<host>.json` of Claude Code background tasks here.
TASKS_DIR = os.path.expanduser(
    os.environ.get("FIELDNOTES_TASKS_DIR", "~/.local/state/fieldnotes/agent-tasks")
)
# A host that has not pushed for this long is shown as stale.
TASKS_STALE_SECONDS = 90


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


def provider_problem(error: object) -> str:
    text = str(error or "unavailable")
    if "credentials.json" in text or "No such file" in text:
        return "not signed in"
    if "no API key" in text:
        return "no API key"
    return text.splitlines()[0]


def fetch_usage() -> tuple[list[dict], str | None]:
    data, error = command_json(["ai-usagebar", "usage", "--json"])
    if error:
        return [], error
    entries = data.get("entries", []) if isinstance(data, dict) else []
    rows = []
    failures = []
    for entry in entries:
        provider = entry.get("display_name", entry.get("id", "Provider"))
        if entry.get("status") != "ready":
            failures.append(
                {"provider": provider, "problem": provider_problem(entry.get("error"))}
            )
            continue
        for metric in entry.get("metrics", []):
            percent = metric.get("percent")
            if percent is None:
                continue
            rows.append(
                {
                    "provider": provider,
                    "label": metric.get("label", "Usage"),
                    "value": metric.get("value", "—"),
                    "percent": max(0, min(100, int(percent))),
                    "reset": metric.get("reset_at"),
                }
            )
    return rows + failures, None


def fetch_runs() -> tuple[list[dict], str | None]:
    data, error = command_json(
        ["gh", "api", f"repos/{CI_REPO}/actions/runs?per_page=40"]
    )
    if error:
        return [], error
    runs = data.get("workflow_runs", []) if isinstance(data, dict) else []
    # GitHub stops listing a workflow once its file leaves the default branch,
    # but keeps showing that workflow's old runs.
    workflows, error = command_json(["gh", "api", f"repos/{CI_REPO}/actions/workflows"])
    if error:
        return [], error
    active = {
        workflow.get("path")
        for workflow in (workflows or {}).get("workflows", [])
        if workflow.get("state") == "active"
    }
    return [
        {
            "workflowName": run.get("name"),
            "displayTitle": run.get("display_title"),
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "createdAt": run.get("created_at"),
            "headBranch": run.get("head_branch"),
            "headSha": run.get("head_sha"),
            "path": run.get("path"),
            "retired": run.get("path") not in active,
        }
        for run in runs
    ], None


# Workflow path -> (commit it was read at, one-line description).
WORKFLOW_ABOUT: dict[str, tuple[str, str]] = {}


def workflow_about(path: str, sha: str) -> str:
    """The first sentence of a workflow file's top-level header comment."""
    # Dependabot and Copilot runs have no file in the repository.
    if not path.startswith(".github/workflows/"):
        return "managed by GitHub"
    cached = WORKFLOW_ABOUT.get(path)
    if cached and cached[0] == sha:
        return cached[1]
    data, error = command_json(
        ["gh", "api", f"repos/{CI_REPO}/contents/{path}?ref={sha}"]
    )
    if error or not isinstance(data, dict):
        return cached[1] if cached else ""
    try:
        text = base64.b64decode(data.get("content", "")).decode()
    except ValueError:
        return cached[1] if cached else ""
    comment: list[str] = []
    for line in text.splitlines():
        if line.startswith("#"):
            comment.append(line.lstrip("#").strip())
        elif comment or line.startswith("jobs:"):
            break
    about = " ".join(comment).split(". ")[0].rstrip(".")
    WORKFLOW_ABOUT[path] = (sha, about)
    return about


def run_state(run: dict) -> str:
    if run.get("status") != "completed":
        return "running"
    conclusion = run.get("conclusion")
    if conclusion == "success":
        return "passed"
    if conclusion in ("cancelled", "skipped", "neutral"):
        return "skipped"
    return "failed"


def summarize_runs(runs: list[dict]) -> tuple[list[dict], list[dict]]:
    """Reduce newest-first runs to what needs attention.

    Returns each workflow's verdict on main, with how many pushes in a row it
    has failed, and the latest failing or running run of each other branch.
    Superseded (cancelled) runs are ignored, since a newer push replaced them.
    """
    runs = [run for run in runs if run_state(run) != "skipped"]
    history: dict[str, list[dict]] = {}
    branches: dict[tuple[str, str], dict] = {}
    for run in runs:
        name = run.get("workflowName") or "workflow"
        branch = run.get("headBranch") or ""
        if branch == "main":
            history.setdefault(name, []).append(run)
        else:
            branches.setdefault((name, branch), run)
    main = []
    for name, main_runs in history.items():
        latest = main_runs[0]
        # A workflow removed from main never runs again, so its last verdict
        # is history rather than something to fix.
        state = "retired" if latest.get("retired") else run_state(latest)
        streak = 0
        for run in main_runs:
            if run_state(run) != "failed":
                break
            streak += 1
        path = latest.get("path") or ""
        main.append(
            {
                "name": name,
                "state": state,
                "last": run_state(latest),
                "path": path,
                "about": workflow_about(path, latest.get("headSha") or "main"),
                "title": latest.get("displayTitle"),
                "when": parse_time(latest.get("createdAt")),
                "streak": streak,
                # Every fetched run failed, so the streak may be longer.
                "streak_open": streak == len(main_runs),
            }
        )
    order = {"failed": 0, "running": 1, "passed": 2}
    main.sort(key=lambda item: order.get(item["state"], 3))
    others = [
        {
            "name": name,
            "branch": branch,
            "state": run_state(run),
            "title": run.get("displayTitle"),
            "when": parse_time(run.get("createdAt")),
        }
        for (name, branch), run in branches.items()
        if run_state(run) in ("failed", "running") and not run.get("retired")
    ]
    return main, others


def knot_query(method: str, params: dict) -> dict:
    url = f"{TANGLED_KNOT}/xrpc/{method}?{urllib.parse.urlencode(params)}"
    # The knot refuses urllib's default User-Agent.
    request = urllib.request.Request(
        url, headers={"User-Agent": "fieldnotes-wallpaper"}
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.load(response)


def fetch_topics() -> tuple[list[dict], str | None]:
    """Published topics that have not landed on main, longest-waiting first."""
    try:
        branches = knot_query(
            "sh.tangled.repo.branches", {"repo": TANGLED_REPO_DID}
        ).get("branches", [])
        log = knot_query(
            "sh.tangled.repo.log",
            {"repo": TANGLED_REPO_DID, "ref": "main", "limit": 200},
        ).get("commits", [])
    except (OSError, ValueError) as error:
        return [], f"Tangled knot unreachable: {error}"
    # `ci land` rebases a topic before it lands, so a landed topic's branch
    # may still name the pre-rebase commit; match its title as well.
    landed_hashes = {bytes(commit.get("hash", [])).hex() for commit in log}
    landed_titles = {
        (commit.get("message") or "").splitlines()[0]
        for commit in log
        if commit.get("message")
    }
    topics = []
    for branch in branches:
        name = branch.get("reference", {}).get("name", "")
        if not name.startswith("jj-"):
            continue
        commit = branch.get("commit", {})
        title = (commit.get("Message") or name).splitlines()[0]
        if branch["reference"].get("hash") in landed_hashes or title in landed_titles:
            continue
        topics.append(
            {
                "title": title,
                "updated": parse_time(commit.get("Committer", {}).get("When")),
            }
        )
    now = datetime.now().astimezone()
    topics.sort(key=lambda topic: topic["updated"] or now)
    return topics, None


def waiting_too_long(topic: dict) -> bool:
    updated = topic["updated"]
    return (
        updated is not None
        and (datetime.now().astimezone() - updated).days >= TOPIC_STALE_DAYS
    )


def parse_time(value: object) -> datetime | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone()
    except (ValueError, TypeError):
        return None


def load_tasks() -> list[dict]:
    try:
        names = sorted(os.listdir(TASKS_DIR))
    except OSError:
        return []
    now = datetime.now().astimezone()
    tasks = []
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(TASKS_DIR, name), encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        updated = parse_time(data.get("updated"))
        stale = updated is None or (now - updated).total_seconds() > TASKS_STALE_SECONDS
        for task in data.get("tasks", []):
            tasks.append(
                {
                    "host": data.get("host", name.removesuffix(".json")),
                    "description": task.get("description") or task.get("id"),
                    "cwd": task.get("cwd", ""),
                    "started": parse_time(task.get("started")),
                    "finished": parse_time(task.get("finished")),
                    "stale": stale,
                }
            )
    # Running tasks first, newest first within each group.
    tasks.sort(
        key=lambda task: (
            task["finished"] is not None,
            -(task["finished"] or task["started"] or now).timestamp(),
        )
    )
    return tasks


def ago(moment: datetime | None) -> str:
    if moment is None:
        return "—"
    minutes = int((datetime.now().astimezone() - moment).total_seconds() // 60)
    if minutes < 1:
        return "<1m"
    if minutes >= 24 * 60:
        return f"{minutes // 1440}d {minutes % 1440 // 60}h"
    return f"{minutes // 60}h {minutes % 60:02d}m" if minutes >= 60 else f"{minutes}m"


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
    ci: tuple[list[dict], list[dict]],
    ci_error: str | None,
    topics: list[dict],
    topics_error: str | None,
    tasks: list[dict],
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
    draw_panel(screen, right_x, panel_y, right_width, f"CI  /  {CI_REPO}", colors)

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
        for item in usage:
            if "problem" in item:
                if row_y >= height - 3:
                    break
                put(screen, row_y, left_x + 2, "○", colors["amber"], 1)
                put(
                    screen,
                    row_y,
                    left_x + 5,
                    shorten(
                        f"{item['provider']}  —  {item['problem']}", left_width - 7
                    ),
                    colors["muted"],
                    left_width - 7,
                )
                row_y += 1
                continue
            if row_y + 3 > height - 3:
                break
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

    # Each CI line is (marker, marker color, text, text color, right, right color).
    ci_lines: list[tuple[str, int, str, int, str, int]] = []
    marks = {
        "failed": ("✗", colors["coral"]),
        "running": ("●", colors["amber"]),
        "passed": ("✓", colors["mint"]),
        "retired": ("○", colors["muted"]),
    }
    if ci_error:
        ci_lines.append(
            ("○", colors["amber"], "GitHub Actions unavailable", colors["muted"], "", 0)
        )
        ci_lines.append((" ", 0, ci_error, colors["muted"], "", 0))
    else:
        main_runs, other_runs = ci
        for item in main_runs:
            marker, color = marks.get(item["state"], ("○", colors["muted"]))
            if item["state"] == "retired":
                verdict = "retired"
            elif item["state"] == "failed" and item["streak"] > 1:
                more = "+" if item["streak_open"] else ""
                verdict = f"failing ×{item['streak']}{more}"
            else:
                verdict = f"{item['state']} {ago(item['when'])} ago"
            ci_lines.append(
                (
                    marker,
                    color,
                    f"{item['name']}  on main",
                    colors["muted" if item["state"] == "retired" else "normal"],
                    verdict,
                    color,
                )
            )
            # What the workflow does and which file defines it.
            source = os.path.basename(item["path"]) or item["path"]
            about = f"{item['about']}  ·  {source}" if item["about"] else source
            ci_lines.append((" ", 0, f"  {about}", colors["muted"], "", 0))
            if item["state"] == "retired":
                last = f"removed from main; last run {item['last']} {ago(item['when'])} ago"
                ci_lines.append((" ", 0, f"↳ {last}", colors["muted"], "", 0))
            else:
                ci_lines.append((" ", 0, f"↳ {item['title']}", colors["muted"], "", 0))
        for item in other_runs:
            marker, color = marks[item["state"]]
            ci_lines.append(
                (
                    marker,
                    color,
                    f"{item['name']}  on {item['branch']}",
                    colors["normal"],
                    f"{item['state']} {ago(item['when'])} ago",
                    color,
                )
            )
            ci_lines.append((" ", 0, f"↳ {item['title']}", colors["muted"], "", 0))
        if not main_runs and not other_runs:
            ci_lines.append(
                (
                    "○",
                    colors["muted"],
                    "No recent workflow runs.",
                    colors["muted"],
                    "",
                    0,
                )
            )
    ci_lines.append((" ", 0, "", 0, "", 0))
    if topics_error:
        ci_lines.append(
            (
                "○",
                colors["amber"],
                shorten(topics_error, right_width),
                colors["muted"],
                "",
                0,
            )
        )
    else:
        stale = sum(1 for topic in topics if waiting_too_long(topic))
        heading = f"WAITING TO LAND  /  {len(topics)} topics"
        if stale:
            heading += f"  ·  {stale} over {TOPIC_STALE_DAYS}d"
        ci_lines.append((" ", 0, heading, colors["lime"], "", 0))
        if not topics:
            ci_lines.append(
                (
                    "✓",
                    colors["mint"],
                    "Every published topic has landed.",
                    colors["muted"],
                    "",
                    0,
                )
            )
    # Leave at least half the column for the background-task panel below.
    budget = max(6, (visible_rows - 3) // 2)
    topic_lines = []
    for topic in [] if topics_error else topics:
        color = colors["amber"] if waiting_too_long(topic) else colors["mint"]
        topic_lines.append(
            ("●", color, topic["title"], colors["normal"], ago(topic["updated"]), color)
        )
    room = max(0, budget - len(ci_lines))
    if len(topic_lines) > room:
        hidden = len(topic_lines) - max(0, room - 1)
        topic_lines = topic_lines[: max(0, room - 1)]
        topic_lines.append((" ", 0, f"+ {hidden} more", colors["muted"], "", 0))
    ci_lines += topic_lines

    label_width = max(10, right_width - 20)
    for index, (
        marker,
        marker_color,
        text,
        text_color,
        right,
        right_color,
    ) in enumerate(ci_lines):
        row_y = body_y + index
        if not text:
            continue
        put(screen, row_y, right_x + 2, marker, marker_color, 1)
        put(
            screen,
            row_y,
            right_x + 4,
            shorten(text, label_width),
            text_color,
            label_width,
        )
        if right:
            put(
                screen,
                row_y,
                right_x + right_width - 16,
                f"{right:>14}",
                right_color,
                14,
            )
    ci_end = body_y + len(ci_lines)

    tasks_y = ci_end + 1
    running = sum(1 for task in tasks if task["finished"] is None)
    draw_panel(
        screen,
        right_x,
        tasks_y,
        right_width,
        f"CLAUDE BACKGROUND TASKS  /  {running} running",
        colors,
    )
    row_y = tasks_y + 3
    if not tasks:
        put(
            screen,
            row_y,
            right_x + 2,
            "No background tasks reported.",
            colors["muted"],
            right_width - 4,
        )
    label_width = max(10, right_width - 20)
    for task in tasks:
        if row_y + 1 >= height - 3:
            break
        if task["finished"] is not None:
            marker, color = "✓", colors["mint"]
            state = f"done {ago(task['finished'])} ago"
        elif task["stale"]:
            marker, color = "?", colors["amber"]
            state = "host silent"
        else:
            marker, color = "●", colors["lime"]
            state = f"running {ago(task['started'])}"
        put(screen, row_y, right_x + 2, marker, color, 1)
        put(
            screen,
            row_y,
            right_x + 4,
            shorten(task["description"], label_width),
            colors["normal"],
            label_width,
        )
        put(screen, row_y, right_x + right_width - 16, f"{state:>14}", color, 14)
        where = f"↳ {task['host']}  ·  {os.path.basename(task['cwd'].rstrip('/'))}"
        put(
            screen,
            row_y + 1,
            right_x + 4,
            shorten(where, label_width),
            colors["muted"],
            label_width,
        )
        row_y += 2

    divider_y = min(height - 2, max(body_y + 7, height - 3))
    put(screen, divider_y, 2, "─" * max(0, width - 4), colors["muted"], width - 4)
    put(screen, divider_y + 1, 2, "POLLING EVERY 30s", colors["muted"], 20)
    windows = sum(1 for item in usage if "percent" in item)
    put(screen, divider_y + 1, 23, f"AI USAGE  {windows} windows", colors["mint"], 24)
    failing = sum(1 for group in ci for item in group if item["state"] == "failed")
    put(
        screen,
        divider_y + 1,
        48,
        f"CI  {failing} failing",
        colors["coral"] if failing else colors["mint"],
        18,
    )
    put(screen, divider_y + 1, 67, f"TASKS  {running} running", colors["mint"], 20)
    screen.refresh()


def main(screen: curses.window) -> None:
    curses.curs_set(0)
    screen.nodelay(True)
    colors = init_colors()
    last_poll = 0.0
    usage: list[dict] = []
    ci: tuple[list[dict], list[dict]] = ([], [])
    topics: list[dict] = []
    usage_error: str | None = None
    ci_error: str | None = None
    topics_error: str | None = None
    while True:
        key = screen.getch()
        if key in (ord("q"), ord("Q")):
            return
        if key == curses.KEY_RESIZE:
            last_poll = 0
        if time.monotonic() - last_poll >= POLL_SECONDS:
            usage, usage_error = fetch_usage()
            runs, ci_error = fetch_runs()
            ci = summarize_runs(runs)
            topics, topics_error = fetch_topics()
            last_poll = time.monotonic()
        draw(
            screen,
            usage,
            usage_error,
            ci,
            ci_error,
            topics,
            topics_error,
            load_tasks(),
            colors,
        )
        time.sleep(0.5)


if __name__ == "__main__":
    curses.wrapper(main)
