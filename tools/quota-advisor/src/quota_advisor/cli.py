import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from .policy import recommend
from .jev import classify


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
        help="Classify task with OpenRouter Jev (paid API)",
    )
    args = parser.parse_args()
    now = datetime.fromisoformat(args.at) if args.at else datetime.now(timezone.utc)
    snapshot = json.loads(args.snapshot.read_text())
    jev = None
    if args.jev:
        task = snapshot.setdefault("task", {})
        if task.get("privacy") == "sensitive":
            parser.error("Refusing to send a sensitive task to OpenRouter")
        if not task.get("description"):
            parser.error("--jev requires task.description")
        jev = classify(task["description"])
        for field, value in jev["labels"].items():
            task.setdefault(field, value)
    result = recommend(snapshot, now)
    if jev:
        result["jev"] = jev
        result["recommendation"]["review_required"] = True
        result["recommendation"]["reason"] += (
            " Jev classification is advisory until calibrated on your tasks."
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
