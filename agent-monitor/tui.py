#!/usr/bin/env python3
"""Live agent usage, CI, and background tasks in a Textual terminal dashboard."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.widgets import Static


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
    request = urllib.request.Request(url, headers={"User-Agent": "fieldnotes-monitor"})
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
        if not isinstance(data, dict) or not isinstance(data.get("tasks", []), list):
            continue
        updated = parse_time(data.get("updated"))
        stale = updated is None or (now - updated).total_seconds() > TASKS_STALE_SECONDS
        for task in data.get("tasks", []):
            if not isinstance(task, dict):
                continue
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


def reset_label(value: object) -> str:
    reset = parse_time(value)
    if reset is None:
        return ""
    minutes = int((reset - datetime.now().astimezone()).total_seconds() / 60)
    if minutes <= 0:
        return "resetting"
    return (
        f"resets in {minutes // 60}h {minutes % 60:02d}m"
        if minutes >= 60
        else f"resets in {minutes}m"
    )


STATE_STYLES = {
    "failed": "red",
    "running": "yellow",
    "passed": "green",
    "retired": "dim",
}


def usage_text(rows: list[dict]) -> Text:
    text = Text()
    for item in rows:
        if "problem" in item:
            text.append(f"○ {item['provider']} — {item['problem']}\n", "yellow")
            continue
        percent = item["percent"]
        style = "red" if percent >= 90 else "yellow" if percent >= 75 else "cyan"
        filled = round(percent / 5)
        text.append(f"{item['provider']} / {item['label']}\n", "bold")
        text.append(f"{'█' * filled}{'░' * (20 - filled)} {percent}%\n", style)
        text.append(f"{item['value']} used  {reset_label(item['reset'])}\n\n", "dim")
    return text if rows else Text("No active provider windows reported.", "dim")


def ci_text(groups: tuple[list[dict], list[dict]]) -> Text:
    text = Text()
    main, others = groups
    for item in main:
        state = item["state"]
        style = STATE_STYLES.get(state, "dim")
        verdict = state
        if state == "failed" and item["streak"] > 1:
            more = "+" if item["streak_open"] else ""
            verdict = f"failing ×{item['streak']}{more}"
        text.append(f"{item['name']} on main — {verdict}\n", style)
        source = os.path.basename(item["path"]) or item["path"]
        text.append(f"{item['about']} · {source}\n", "dim")
        if state == "retired":
            text.append(
                f"Removed from main; last run {item['last']} {ago(item['when'])} ago\n",
                "dim",
            )
        else:
            text.append(f"{item['title']} · {ago(item['when'])} ago\n")
        text.append("\n")
    for item in others:
        text.append(
            f"{item['name']} on {item['branch']} — {item['state']}\n",
            STATE_STYLES[item["state"]],
        )
        text.append(f"{item['title']} · {ago(item['when'])} ago\n\n", "dim")
    return text if main or others else Text("No recent workflow runs.", "dim")


def topics_text(topics: list[dict]) -> Text:
    text = Text()
    for topic in topics:
        stale = waiting_too_long(topic)
        text.append(f"{topic['title']}\n", "yellow" if stale else "green")
        label = f" · waiting over {TOPIC_STALE_DAYS}d" if stale else ""
        text.append(f"Updated {ago(topic['updated'])} ago{label}\n\n", "dim")
    return text if topics else Text("Every published topic has landed.", "green")


def tasks_text(tasks: list[dict]) -> Text:
    text = Text()
    for task in tasks:
        if task["finished"] is not None:
            state, style = f"done {ago(task['finished'])} ago", "green"
        elif task["stale"]:
            state, style = "host silent", "yellow"
        else:
            state, style = f"running {ago(task['started'])}", "cyan"
        text.append(f"{task['description']} — {state}\n", style)
        text.append(f"{task['host']} · {task['cwd']}\n\n", "dim")
    return text if tasks else Text("No background tasks reported.", "dim")


def fetch_ci() -> tuple[tuple[list[dict], list[dict]], str | None]:
    runs, error = fetch_runs()
    return summarize_runs(runs) if not error else ([], []), error


class DashboardBody(VerticalScroll, inherit_bindings=False):
    # One shared keymap lives on the app and is always visible below the body.
    can_focus = False


class AgentMonitor(App, inherit_bindings=False):
    TITLE = "Fieldnotes / Agent Monitor"
    ENABLE_COMMAND_PALETTE = False
    BINDINGS = [
        Binding("up", "scroll('up')", "Scroll up", key_display="↑"),
        Binding("down", "scroll('down')", "Scroll down", key_display="↓"),
        Binding("pageup", "scroll('page_up')", "Page up", key_display="PgUp"),
        Binding("pagedown", "scroll('page_down')", "Page down", key_display="PgDn"),
        Binding("home", "scroll('home')", "Top", key_display="Home"),
        Binding("end", "scroll('end')", "Bottom", key_display="End"),
        Binding("r", "poll", "Refresh", key_display="R"),
        Binding("q,ctrl+c", "quit", "Quit", key_display="Q/Ctrl+C"),
    ]
    CSS = """
    Screen { background: $background; }
    #title { height: auto; padding: 0 1; background: $primary-background; }
    DashboardBody { height: 1fr; padding: 0 1; }
    .panel { height: auto; border: round $primary; padding: 1 2; margin-bottom: 1; }
    #status, #keys { height: auto; padding: 0 1; background: $primary-background; }
    """

    def __init__(self) -> None:
        super().__init__()
        self.data = {"usage": [], "ci": ([], []), "topics": []}
        self.errors: dict[str, str | None] = {}
        self.updated: dict[str, datetime] = {}
        self.pending: set[str] = set()
        self.loaders = {"usage": fetch_usage, "ci": fetch_ci, "topics": fetch_topics}
        self.renderers = {"usage": usage_text, "ci": ci_text, "topics": topics_text}

    def compose(self) -> ComposeResult:
        yield Static(self.TITLE, id="title")
        with DashboardBody(id="body"):
            for name in ("usage", "ci", "topics", "tasks"):
                yield Static("Loading…", id=name, classes="panel", markup=False)
        yield Static("Mode: Normal · Starting…", id="status", markup=False)
        hints = "  ·  ".join(
            f"{binding.key_display} {binding.description}" for binding in self.BINDINGS
        )
        yield Static(hints, id="keys", markup=False)

    def on_mount(self) -> None:
        titles = {
            "usage": "Provider windows",
            "ci": f"CI / {CI_REPO}",
            "topics": "Waiting to land",
            "tasks": "Claude background tasks",
        }
        for name, title in titles.items():
            self.query_one(f"#{name}", Static).border_title = title
        self.action_poll()
        self.set_interval(POLL_SECONDS, self.action_poll)
        self.set_interval(1, self.render_data)

    def action_scroll(self, direction: str) -> None:
        body = self.query_one(DashboardBody)
        getattr(body, f"action_scroll_{direction}")()

    def action_poll(self) -> None:
        for name in self.loaders:
            if name not in self.pending:
                self.pending.add(name)
                self.run_worker(self.poll_source(name), group=name)
        self.render_data()

    async def poll_source(self, name: str) -> None:
        try:
            data, error = await asyncio.to_thread(self.loaders[name])
            self.errors[name] = error
            if error is None:
                self.data[name] = data
                self.updated[name] = datetime.now().astimezone()
        except Exception as error:
            self.errors[name] = str(error)
        finally:
            self.pending.discard(name)
        self.render_data()

    def render_data(self) -> None:
        for name, renderer in self.renderers.items():
            content = Text()
            error = self.errors.get(name)
            if error:
                content.append(f"Unavailable: {error}\n", "yellow")
                if name in self.updated:
                    content.append(
                        f"Showing last successful data from {ago(self.updated[name])} ago\n\n",
                        "dim",
                    )
            if name in self.updated:
                content.append_text(renderer(self.data[name]))
            elif not error:
                content.append("Loading…", "dim")
            self.query_one(f"#{name}", Static).update(content)
        tasks = load_tasks()
        panel = self.query_one("#tasks", Static)
        panel.update(tasks_text(tasks))
        running = sum(task["finished"] is None for task in tasks)
        panel.border_title = f"Claude background tasks / {running} running"
        refreshing = ", ".join(sorted(self.pending))
        state = (
            f"Refreshing {refreshing}" if refreshing else f"Poll every {POLL_SECONDS}s"
        )
        clock = datetime.now().astimezone().strftime("%a %d %b %H:%M:%S")
        self.query_one("#status", Static).update(f"Mode: Normal · {state} · {clock}")


if __name__ == "__main__":
    AgentMonitor().run()
