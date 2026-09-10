#!/usr/bin/env python3
"""Receive GitHub workflow_run events and synchronize a local JJ checkout."""

import hashlib
import hmac
import http.server
import json
import logging
import os
import queue
import shlex
import subprocess
import threading
from pathlib import Path

MAX_PAYLOAD_BYTES = 1024 * 1024


def required_setting(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"missing required setting {name}")
    return value


PROJECT_DIR = Path(required_setting("JJ_CI_WEBHOOK_PROJECT_DIR"))
REPOSITORY = required_setting("JJ_CI_WEBHOOK_REPOSITORY")
WORKFLOW = required_setting("JJ_CI_WEBHOOK_WORKFLOW")
WEBHOOK_PATH = required_setting("JJ_CI_WEBHOOK_PATH")
WEBHOOK_SECRET = required_setting("JJ_CI_WEBHOOK_SECRET").encode("utf-8")
SYNC_COMMAND = shlex.split(required_setting("JJ_CI_WEBHOOK_SYNC_COMMAND"))
LISTEN_ADDRESS = os.environ.get("JJ_CI_WEBHOOK_LISTEN_ADDRESS", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("JJ_CI_WEBHOOK_LISTEN_PORT", "8765"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("jj-ci-webhook")


def signature_is_valid(body: bytes, signature: str | None) -> bool:
    if not signature or not signature.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(WEBHOOK_SECRET, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def event_requests_sync(event: str | None, payload: dict) -> tuple[bool, str]:
    if event != "workflow_run":
        return False, "ignoring non-workflow_run event"
    if payload.get("action") != "completed":
        return False, "ignoring workflow_run action"

    repository = payload.get("repository", {}).get("full_name")
    workflow_run = payload.get("workflow_run", {})
    workflow = payload.get("workflow", {}) or {}
    if repository != REPOSITORY:
        return False, f"ignoring repository {repository!r}"
    if workflow.get("name") != WORKFLOW:
        return False, f"ignoring workflow {workflow.get('name')!r}"
    if workflow_run.get("head_branch") != "main":
        return False, f"ignoring branch {workflow_run.get('head_branch')!r}"
    if workflow_run.get("conclusion") != "success":
        return False, f"ignoring conclusion {workflow_run.get('conclusion')!r}"

    head_sha = workflow_run.get("head_sha")
    if not head_sha:
        return False, "ignoring event without a head SHA"
    return True, head_sha


class SyncWorker:
    def __init__(self) -> None:
        self.pending: queue.Queue[str] = queue.Queue(maxsize=1)
        self.seen: set[str] = set()
        self.lock = threading.Lock()
        threading.Thread(target=self.run, name="jj-ci-sync", daemon=True).start()

    def enqueue(self, head_sha: str) -> bool:
        with self.lock:
            if head_sha in self.seen:
                return False
            self.seen.add(head_sha)
        try:
            self.pending.put_nowait(head_sha)
        except queue.Full:
            logger.warning("sync already queued; dropping duplicate head SHA %s", head_sha)
            return False
        return True

    def run(self) -> None:
        while True:
            head_sha = self.pending.get()
            try:
                logger.info("syncing %s after successful validation of %s", REPOSITORY, head_sha)
                completed = subprocess.run(
                    SYNC_COMMAND,
                    cwd=PROJECT_DIR,
                    check=False,
                    timeout=1800,
                    env=os.environ.copy(),
                )
                if completed.returncode:
                    logger.error("sync failed with exit code %s", completed.returncode)
                else:
                    logger.info("sync completed for %s", head_sha)
            except (OSError, subprocess.TimeoutExpired) as error:
                logger.exception("sync failed: %s", error)
            finally:
                self.pending.task_done()


worker = SyncWorker()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "jj-ci-webhook/1"

    def log_message(self, format: str, *args: object) -> None:
        logger.info("%s - %s", self.address_string(), format % args)

    def send_text(self, status: int, message: str) -> None:
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self.send_text(200, "ok\n")
        else:
            self.send_text(404, "not found\n")

    def do_POST(self) -> None:  # noqa: N802
        if self.path != WEBHOOK_PATH:
            self.send_text(404, "not found\n")
            return

        try:
            content_length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            content_length = -1
        if content_length < 0 or content_length > MAX_PAYLOAD_BYTES:
            self.send_text(413, "payload too large\n")
            return

        body = self.rfile.read(content_length)
        if not signature_is_valid(body, self.headers.get("X-Hub-Signature-256")):
            self.send_text(401, "invalid signature\n")
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_text(400, "invalid JSON\n")
            return

        requested, detail = event_requests_sync(self.headers.get("X-GitHub-Event"), payload)
        if not requested:
            logger.info(detail)
            self.send_text(202, "ignored\n")
            return

        queued = worker.enqueue(detail)
        logger.info(
            "%s sync for delivery %s",
            "queued" if queued else "already queued",
            self.headers.get("X-GitHub-Delivery", "unknown"),
        )
        self.send_text(202, "accepted\n")


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    with Server((LISTEN_ADDRESS, LISTEN_PORT), Handler) as server:
        logger.info("listening on %s:%s%s", LISTEN_ADDRESS, LISTEN_PORT, WEBHOOK_PATH)
        server.serve_forever()
