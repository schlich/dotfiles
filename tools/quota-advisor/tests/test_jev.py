import io
import json
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from quota_advisor import cli
from quota_advisor.jev import JevUnavailable, classify

EXAMPLE_PATH = Path(__file__).parents[1] / "example.json"
REPLY = {
    "model": "jev-1.13.0",
    "answers": {
        "difficulty": {"type": "choice", "choice": "medium", "confidence": 0.8},
        "error_cost": {"type": "choice", "choice": "high", "confidence": 0.7},
    },
    "usage": {"input_tokens": 120, "output_tokens": 4},
}


def runner(returncode=0, stdout="", stderr="", calls=None):
    def run(args, **kwargs):
        if calls is not None:
            calls.append((args, kwargs))
        return subprocess.CompletedProcess(args, returncode, stdout, stderr)

    return run


class JevTest(unittest.TestCase):
    def test_sends_only_the_task_to_jev_classify_task(self):
        calls = []
        with mock.patch.dict("os.environ", {"QUOTA_ADVISOR_JEV": "/bin/jev"}):
            result = classify(
                "Review migration", run=runner(stdout=json.dumps(REPLY), calls=calls)
            )
        self.assertEqual(result["labels"], {"difficulty": "medium", "error_cost": "high"})
        args, kwargs = calls[0]
        self.assertEqual(args, ["/bin/jev", "classify-task"])
        self.assertEqual(json.loads(kwargs["input"]), {"task": "Review migration"})

    def test_failed_jev_is_unavailable(self):
        with self.assertRaisesRegex(JevUnavailable, "HTTP 402"):
            classify("x", run=runner(returncode=1, stderr="Error:\n  Jev request failed with HTTP 402"))

    def test_missing_jev_is_unavailable(self):
        def run(args, **kwargs):
            raise FileNotFoundError(2, "No such file or directory", args[0])

        with self.assertRaises(JevUnavailable):
            classify("x", run=run)

    def test_unexpected_label_is_unavailable(self):
        reply = json.loads(json.dumps(REPLY))
        reply["answers"]["difficulty"]["choice"] = "extreme"
        with self.assertRaises(JevUnavailable):
            classify("x", run=runner(stdout=json.dumps(reply)))

    def test_cli_falls_back_to_the_offline_policy(self):
        argv = ["quota-advisor", str(EXAMPLE_PATH), "--at", "2026-09-29T07:45:00-05:00", "--jev"]
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch("sys.argv", argv),
            mock.patch.object(cli, "classify", side_effect=JevUnavailable("no credits")),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            cli.main()
        result = json.loads(stdout.getvalue())
        self.assertEqual(result["jev"], {"unavailable": "no credits"})
        self.assertEqual(result["recommendation"]["tool"], "claude")
        self.assertFalse(result["recommendation"]["review_required"])
        self.assertIn("no credits", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
