"""Renders findings into one static, self-contained HTML page.

The page embeds its data, needs no server beyond a static file host, and
keeps only per-browser conveniences (which findings you marked seen) in
localStorage."""

import json
from pathlib import Path

TEMPLATE = (Path(__file__).parent / "dashboard.html").read_text()


def render(runs: list[dict], findings: list[dict], min_score: int, out: Path) -> Path:
    data = {
        "minScore": min_score,
        "runs": [
            {"id": r["id"], "started": r["started"], "overview": r["overview"], "stats": r["stats"]}
            for r in runs
        ],
        "findings": [
            {
                "id": f["id"],
                "run": f["run_id"],
                "guild": f["guild"],
                "guildId": str(f["guild_id"]),
                "channel": f["channel"],
                "channelId": str(f["channel_id"]),
                "title": f["title"],
                "summary": f["summary"],
                "category": f["category"],
                "score": f["score"],
                "why": f["why"],
                "messageIds": f["message_ids"],
                "at": f["first_message_at"],
            }
            for f in findings
        ],
    }
    # JSON inside <script> must not be able to close the tag.
    payload = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(TEMPLATE.replace("/*DATA*/null", payload))
    return out
