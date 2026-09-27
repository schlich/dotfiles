#!/usr/bin/env python3
"""Focused unit and socket tests for the local GitHub webhook."""

import hashlib
import hmac
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest import mock


os.environ.update(
    {
        "JJ_CI_WEBHOOK_PROJECT_DIR": "/tmp/dotfiles-test",
        "JJ_CI_WEBHOOK_REPOSITORY": "schlich/dotfiles",
        "JJ_CI_WEBHOOK_WORKFLOW": "nix-ci",
        "JJ_CI_WEBHOOK_PATH": "/github/webhook",
        "JJ_CI_WEBHOOK_SECRET": "test-secret",
        "JJ_CI_WEBHOOK_SYNC_COMMAND": "jj-ci sync",
        "JJ_CI_WEBHOOK_REFRESH_COMMAND": "jj-ci refresh",
        "JJ_CI_WEBHOOK_AGENT_COMMAND": "codex exec",
    }
)

SCRIPT = Path(__file__).parents[1] / "scripts" / "jj-ci-webhook.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("jj_ci_webhook", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
webhook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webhook)


def successful_run(
    *, action="completed", repository=None, workflow=None, **run_overrides
):
    run = {
        "id": 42,
        "event": "push",
        "head_branch": "main",
        "head_sha": "a" * 40,
        "conclusion": "success",
        "html_url": "https://github.com/schlich/dotfiles/actions/runs/42",
        "pull_requests": [],
    }
    run.update(run_overrides)
    return {
        "action": action,
        "repository": repository or {"full_name": "schlich/dotfiles"},
        "workflow": workflow or {"name": "nix-ci"},
        "workflow_run": run,
    }


def signed_headers(body, event="workflow_run"):
    signature = hmac.new(b"test-secret", body, hashlib.sha256).hexdigest()
    return {
        "Content-Type": "application/json",
        "X-GitHub-Event": event,
        "X-Hub-Signature-256": f"sha256={signature}",
        "X-GitHub-Delivery": "delivery-1",
    }


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.worker = webhook.WebhookWorker(start_thread=False)
        self.server = webhook.Server(
            ("127.0.0.1", 0), webhook.Handler, self.worker, request_timeout=1
        )
        self.server_thread = threading.Thread(target=self.server.serve_forever)
        self.server_thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join()

    def request(self, body, headers=None, path=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request(
            "POST",
            path or webhook.WEBHOOK_PATH,
            body=body,
            headers=headers or signed_headers(body),
        )
        response = connection.getresponse()
        result = (response.status, response.read())
        connection.close()
        return result

    def test_accepts_valid_signature_and_rejects_invalid_signature(self):
        body = json.dumps(successful_run()).encode()
        self.assertTrue(
            webhook.signature_is_valid(
                body, signed_headers(body)["X-Hub-Signature-256"]
            )
        )
        self.assertFalse(webhook.signature_is_valid(body, "sha256=wrong"))
        self.assertFalse(webhook.signature_is_valid(body, None))

        self.assertEqual(self.request(body)[0], 202)
        self.assertEqual(self.request(body)[1], b"already queued\n")

        headers = signed_headers(body)
        headers["X-Hub-Signature-256"] = "sha256=wrong"
        self.assertEqual(self.request(body, headers), (401, b"invalid signature\n"))

    def test_filters_untrusted_or_unrelated_workflow_runs(self):
        rejected = [
            ("push", successful_run()),
            ("workflow_run", successful_run(action="requested")),
            ("workflow_run", successful_run(repository={"full_name": "other/repo"})),
            ("workflow_run", successful_run(workflow={"name": "other"})),
            ("workflow_run", successful_run(conclusion="failure")),
            ("workflow_run", successful_run(head_sha="")),
        ]
        for event, payload in rejected:
            with self.subTest(event=event, payload=payload):
                action, _ = webhook.event_requests_action(event, payload)
                self.assertIsNone(action)

        payload = successful_run()
        action, _ = webhook.event_requests_action("workflow_run", payload)
        self.assertEqual(action["kind"], "sync_and_triage")

        payload = successful_run(
            event="pull_request",
            pull_requests=[{"number": 7}, {"number": 7}, {"number": 9}],
        )
        action, _ = webhook.event_requests_action("workflow_run", payload)
        self.assertEqual(action["kind"], "triage")
        self.assertEqual(
            [pull["number"] for pull in action["context"]["pull_requests"]], [7, 9]
        )

    def test_does_not_forward_webhook_secret_to_local_commands(self):
        worker = webhook.WebhookWorker(start_thread=False)
        with mock.patch.object(
            webhook.subprocess, "run", return_value=mock.Mock(returncode=0)
        ) as run:
            self.assertTrue(worker.run_local("sync", ["jj-ci", "sync"], "a" * 40))
        self.assertNotIn("JJ_CI_WEBHOOK_SECRET", run.call_args.kwargs["env"])

    def test_deduplicates_deliveries_and_rejects_queue_saturation(self):
        worker = webhook.WebhookWorker(queue_size=1, start_thread=False)
        first = {"id": "first", "head_sha": "1"}
        second = {"id": "second", "head_sha": "2"}
        self.assertEqual(worker.enqueue(first), "queued")
        self.assertEqual(worker.enqueue(first), "duplicate")
        self.assertEqual(worker.enqueue(second), "full")

    def test_rejects_oversized_body_before_reading_it(self):
        body = b"{}"
        headers = signed_headers(body)
        headers["Content-Length"] = str(webhook.MAX_PAYLOAD_BYTES + 1)
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        connection.request("POST", webhook.WEBHOOK_PATH, headers=headers)
        response = connection.getresponse()
        self.assertEqual(response.status, 413)
        connection.close()

    def test_rejects_slow_connection_and_reuses_bounded_capacity(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join()

        server = webhook.Server(
            ("127.0.0.1", 0),
            webhook.Handler,
            webhook.WebhookWorker(start_thread=False),
            request_timeout=0.2,
            max_connections=1,
        )
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            slow = socket.create_connection(server.server_address, timeout=1)
            slow.sendall(b"GET / HTTP/1.1\r\n")
            time.sleep(0.05)

            excess = socket.create_connection(server.server_address, timeout=1)
            excess.settimeout(1)
            excess.sendall(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
            self.assertEqual(excess.recv(1), b"")
            excess.close()
            self.assertEqual(slow.recv(1), b"")
            slow.close()

            connection = http.client.HTTPConnection(*server.server_address, timeout=2)
            connection.request("GET", "/healthz")
            self.assertEqual(connection.getresponse().status, 200)
            connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
