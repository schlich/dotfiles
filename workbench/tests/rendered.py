"""Check the HTML view that `workbench export` renders for the demo.

Usage: python rendered.py DEMO.html ENVIRONMENT

The export executes every cell headlessly, so this proves that marimo ran the
document in the declared Nix environment and that the notebook reached the
IWE graph through iwe_bridge.
"""

from __future__ import annotations

import html
import json
import re
import sys
from pathlib import Path


def main(page: Path, environment: str) -> None:
    text = page.read_text()
    assert "marimo-error" not in text, "a cell raised an error"

    # The reactive result at the slider defaults (d' = 1.5, threshold = 0.75).
    # Rendered HTML escapes "<" as a JSON unicode escape (backslash, u003C).
    lt, gt = chr(92) + "u003C", chr(92) + "u003E"
    assert f"hit rate is {lt}strong{gt}0.773" in text, "missing hit rate"
    assert f"false-alarm rate is {lt}strong{gt}0.227" in text

    # The table's rows sit in a JSON-escaped attribute holding HTML-escaped,
    # JSON-encoded JSON: undo each layer in turn.
    match = re.search(r"marimo-table [^>]*?data-data='([^']*)'", text)
    assert match, "missing provenance table"
    attribute = match.group(1).encode("ascii").decode("unicode_escape")
    rows = json.loads(json.loads(html.unescape(attribute)))
    provenance = {row["field"]: row["value"] for row in rows}
    print(json.dumps(provenance, indent=2))

    assert provenance["IWE key"] == "investigations/executable-knowledge-demo"
    assert provenance["declared environment"] == environment
    assert provenance["running environment"] == environment
    assert provenance["matches"] == "True"
    assert provenance["interpreter prefix"].startswith("/nix/store/")
    assert provenance["included by"] == "projects/executable-knowledge"
    print("rendered: ok")


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2])
