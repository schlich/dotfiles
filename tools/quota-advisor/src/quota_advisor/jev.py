"""Optional semantic task classification through the dotfiles `jev` command.

`jev classify-task` owns the questions (jev/questions.nuon), the TypeSafe key,
the usage ledger, and TYPESAFE_BASE_URL for a local decision model, so this
module only runs it and validates the labels.
"""

import json
import os
import subprocess

LABELS = ("low", "medium", "high")
# jev itself gives up on the HTTP request after 15 seconds; this also covers
# Nushell startup and the keyring lookup.
TIMEOUT = 30


class JevUnavailable(Exception):
    """Jev could not label the task; the advisor continues offline."""


def command() -> str:
    return os.environ.get("QUOTA_ADVISOR_JEV") or "jev"


def classify(description: str, run=subprocess.run) -> dict:
    try:
        completed = run(
            [command(), "classify-task"],
            input=json.dumps({"task": description}),
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise JevUnavailable(str(error)) from error
    if completed.returncode != 0:
        detail = " ".join(completed.stderr.split())
        raise JevUnavailable(detail or f"jev exited with {completed.returncode}")
    try:
        result = json.loads(completed.stdout)
        answers = result["answers"]
        labels = {field: answers[field]["choice"] for field in ("difficulty", "error_cost")}
    except (ValueError, KeyError, TypeError) as error:
        raise JevUnavailable(f"unexpected jev response: {error!r}") from error
    for field, label in labels.items():
        if label not in LABELS:
            raise JevUnavailable(f"unexpected Jev answer for {field}: {label!r}")
    return {
        "labels": labels,
        "answers": answers,
        "model": result.get("model"),
        "usage": result.get("usage"),
        "unvalidated_probabilities": True,
    }
