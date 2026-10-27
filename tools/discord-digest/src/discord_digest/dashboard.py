"""Renders findings into one static, self-contained HTML page.

The page embeds its data, needs no server beyond a static file host, and
keeps only per-browser conveniences (which findings you marked seen) in
localStorage."""

import json
import re
from pathlib import Path

TEMPLATE = (Path(__file__).parent / "dashboard.html").read_text()
# The data goes in place of whatever the template's #data element holds, so
# a formatter reflowing its placeholder can't break the substitution.
DATA_ELEMENT = re.compile(r'(<script id="data" type="application/json">).*?(</script>)', re.DOTALL)


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
    html, count = DATA_ELEMENT.subn(lambda m: m[1] + payload + m[2], TEMPLATE, count=1)
    if count != 1:
        raise RuntimeError("dashboard.html lost its <script id=\"data\"> element")
    out.write_text(html)
    return out
