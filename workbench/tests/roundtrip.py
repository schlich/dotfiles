"""Prove that one Markdown file can be an IWE node and a marimo notebook.

Usage: python roundtrip.py WORKSPACE

WORKSPACE is a disposable copy of workbench/. The test edits the demo through
marimo's editor save path (`AppFileManager.save`, the function behind the
editor's save endpoint), then checks that

1. every IWE frontmatter key survives with its value;
2. the prose, headings, and links survive;
3. IWE still validates and resolves the document's graph neighbours;
4. IWE normalization (which rewrites fences as ``` python {.marimo})
   leaves marimo's view of the cells unchanged;
5. the version-control diff contains the edit and nothing else, apart from
   the final newline: marimo strips the rendered document on save
   (marimo/_convert/markdown/flavor/base.py), so a file that ended in a
   newline loses it. The diff comes from `jj diff --git` when WORKSPACE is a
   JJ repository, so the check sees exactly what review would see.
"""

from __future__ import annotations

import difflib
import json
import shutil
import subprocess
import sys
from pathlib import Path

from marimo._convert.converters import MarimoConvert
from marimo._convert.markdown.to_ir import extract_frontmatter
from marimo._server.models.models import SaveNotebookRequest
from marimo._session.notebook.file_manager import AppFileManager

KEY = "investigations/executable-knowledge-demo"
OLD = "value=0.75"
NEW = "value=1.25"
IWE_KEYS = {"type", "status", "project", "environment", "title"}


def iwe(*args: str, cwd: Path) -> str:
    result = subprocess.run(
        ["iwe", *args], cwd=cwd, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, f"iwe {' '.join(args)}: {result.stderr}"
    return result.stdout


def code_cells(text: str) -> list[str]:
    cells = MarimoConvert.from_md(text).to_ir().cells
    return [cell.code for cell in cells if not cell.code.startswith("mo.md(")]


def save_with_edit(path: Path) -> None:
    manager = AppFileManager(str(path))
    cells = list(manager.app.cell_manager.cell_data())
    codes = [cell.code.replace(OLD, NEW) for cell in cells]
    assert codes != [cell.code for cell in cells], "the edit did not apply"
    manager.save(
        SaveNotebookRequest(
            cell_ids=[cell.cell_id for cell in cells],
            codes=codes,
            names=[cell.name for cell in cells],
            configs=[cell.config for cell in cells],
            filename=str(path),
            persist=True,
        )
    )


def main(workspace: Path) -> None:
    path = workspace / "knowledge" / f"{KEY}.md"
    before = path.read_text()
    meta_before, _ = extract_frontmatter(before)

    save_with_edit(path)
    after = path.read_text()
    meta_after, _ = extract_frontmatter(after)

    # 1. IWE metadata survives the editor save.
    for key in IWE_KEYS:
        assert meta_after.get(key) == meta_before.get(key), (key, meta_after)
    assert set(meta_after) - set(meta_before) <= {"marimo-version"}, meta_after

    # 2. Prose, headings, and links survive.
    for line in before.splitlines():
        if line.startswith("#") or "](../" in line:
            assert line in after, f"lost line: {line!r}"
    assert NEW in after and OLD not in after

    # 3. IWE still understands the document.
    iwe("schema", "validate", cwd=workspace)
    [node] = json.loads(iwe("find", "-k", KEY, "-f", "json", cwd=workspace))
    assert node["environment"] == meta_before["environment"]
    assert {ref["key"] for ref in node["references"]} == {
        "concepts/executable-knowledge",
        "concepts/nix-closure-provenance",
    }
    assert [p["key"] for p in node["includedBy"]] == ["projects/executable-knowledge"]

    # 4. IWE's normalized form is still the same marimo notebook.
    cells_before_normalize = code_cells(after)
    iwe("normalize", "-k", KEY, cwd=workspace)
    normalized = path.read_text()
    assert "``` python {.marimo}" in normalized or normalized == after
    assert code_cells(normalized) == cells_before_normalize
    meta_normalized, _ = extract_frontmatter(normalized)
    for key in IWE_KEYS:
        assert meta_normalized.get(key) == meta_before.get(key), key
    # Restore marimo's byte form so the diff below shows only the editor save.
    path.write_text(after)

    # 5. The source change is an ordinary, reviewable Markdown diff.
    if shutil.which("jj") and (workspace / ".jj").is_dir():
        diff = subprocess.run(
            ["jj", "diff", "--git", "--context", "0"],
            cwd=workspace,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
    else:
        diff = list(
            difflib.unified_diff(
                before.splitlines(), after.splitlines(), lineterm="", n=0
            )
        )
    changed = [
        line for line in diff if line[:1] in "+-" and line[:3] not in ("+++", "---")
    ]
    print("\n".join(changed))
    allowed = {
        f'threshold = mo.ui.slider(-2.0, 4.0, step=0.1, {OLD}, label="Threshold")',
        f'threshold = mo.ui.slider(-2.0, 4.0, step=0.1, {NEW}, label="Threshold")',
    }
    last_line = before.rstrip("\n").splitlines()[-1]
    eof_only = before.endswith("\n") and not after.endswith("\n")
    if eof_only:
        allowed.add(last_line)
    unexpected = {
        line[1:].strip()
        for line in changed
        if line[1:].strip() not in allowed and not line.startswith("+marimo-version:")
    }
    assert not unexpected, f"unexpected changes: {unexpected}"
    assert any(NEW in line for line in changed), "the edit is missing from the diff"
    print(f"final newline dropped by marimo: {eof_only}")
    print("roundtrip: ok")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
