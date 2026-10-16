import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .policy import recommend
from .jev import JevUnavailable, classify


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Recommend Codex or Claude from allowance snapshots"
    )
    parser.add_argument(
        "snapshot", type=Path, help="JSON snapshot with task and subscription windows"
    )
    parser.add_argument("--at", help="ISO timestamp for replay; defaults to now")
    parser.add_argument(
        "--log",
        type=Path,
        help="Append recommendation and input snapshot to a local JSONL log",
    )
    parser.add_argument(
        "--actual",
        choices=("codex", "claude", "neither"),
        help="Actual tool chosen, for later evaluation",
    )
    parser.add_argument(
        "--jev",
        action="store_true",
        help="Label the task with `jev classify-task`; falls back to the offline policy",
    )
    args = parser.parse_args()
    now = datetime.fromisoformat(args.at) if args.at else datetime.now(timezone.utc)
    snapshot = json.loads(args.snapshot.read_text())
    jev = None
    jev_error = None
    if args.jev:
        task = snapshot.setdefault("task", {})
        if task.get("privacy") == "sensitive":
            parser.error("Refusing to send a sensitive task to Jev")
        if not task.get("description"):
            parser.error("--jev requires task.description")
        try:
            jev = classify(task["description"])
        except JevUnavailable as error:
            jev_error = str(error)
            print(
                f"quota-advisor: Jev unavailable, using the offline policy: {jev_error}",
                file=sys.stderr,
            )
        else:
            for field, value in jev["labels"].items():
                task.setdefault(field, value)
    result = recommend(snapshot, now)
    if jev:
        result["jev"] = jev
        result["recommendation"]["review_required"] = True
        result["recommendation"]["reason"] += (
            " Jev classification is advisory until calibrated on your tasks."
        )
    elif jev_error:
        result["jev"] = {"unavailable": jev_error}
        result["recommendation"]["reason"] += (
            " Jev was unavailable, so this uses the offline policy."
        )
    if args.actual and not args.log:
        parser.error("--actual requires --log")
    if args.log:
        with args.log.open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {"snapshot": snapshot, "result": result, "actual": args.actual}
                )
                + "\n"
            )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
