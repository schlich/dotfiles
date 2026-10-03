"""Read-only access to an IWE workspace through the stable ``iwe`` CLI.

IWE documents its CLI and MCP server as the supported integration surfaces;
the ``liwe`` library is not API-stable. This module therefore shells out to
``iwe`` and parses its JSON output. It keeps no index of its own.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tomllib
from collections.abc import Iterable
from pathlib import Path
from typing import Any

__all__ = [
    "IweError",
    "find",
    "key_for_path",
    "node",
    "node_for_path",
    "retrieve",
    "tree",
    "validate",
    "workspace_root",
]

# Graph fields in `iwe find -f json`; every other field is frontmatter.
_GRAPH_FIELDS = {"key", "title", "references", "includes", "referencedBy", "includedBy"}


class IweError(RuntimeError):
    """The iwe CLI failed or is unavailable."""


def workspace_root(start: str | os.PathLike[str] | None = None) -> Path:
    """Return the nearest directory at or above ``start`` holding ``.iwe/``.

    ``IWE_WORKSPACE`` overrides the search. ``start`` defaults to the current
    directory.
    """
    if override := os.environ.get("IWE_WORKSPACE"):
        return Path(override).resolve()
    here = Path(start or Path.cwd()).resolve()
    if here.is_file():
        here = here.parent
    for candidate in (here, *here.parents):
        if (candidate / ".iwe" / "config.toml").is_file():
            return candidate
    raise IweError(f"no .iwe/config.toml at or above {here}")


def _library_root(root: Path) -> Path:
    config = tomllib.loads((root / ".iwe" / "config.toml").read_text())
    # IWE 0.25 renamed [library] to [workspace]; accept both.
    section = config.get("workspace") or config.get("library") or {}
    return root / section.get("path", "")


def _run(args: Iterable[str], root: Path) -> str:
    binary = shutil.which("iwe")
    if binary is None:
        raise IweError("the iwe CLI is not on PATH")
    result = subprocess.run(
        [binary, *args], cwd=root, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise IweError(result.stderr.strip() or f"iwe exited with {result.returncode}")
    return result.stdout


def _json(args: list[str], root: Path) -> Any:
    return json.loads(_run([*args, "-f", "json"], root))


def _keys(links: list[dict[str, Any]]) -> list[str]:
    return [link["key"] for link in links]


def _node(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "key": raw["key"],
        "title": raw.get("title"),
        "frontmatter": {k: v for k, v in raw.items() if k not in _GRAPH_FIELDS},
        "references": _keys(raw.get("references", [])),
        "referenced_by": _keys(raw.get("referencedBy", [])),
        "includes": _keys(raw.get("includes", [])),
        "included_by": _keys(raw.get("includedBy", [])),
    }


def find(
    filter: dict[str, Any] | str | None = None,
    *,
    keys: Iterable[str] = (),
    references: str | None = None,
    referenced_by: str | None = None,
    includes: str | None = None,
    included_by: str | None = None,
    lexical: str | None = None,
    limit: int | None = None,
    root: str | os.PathLike[str] | None = None,
) -> list[dict[str, Any]]:
    """Run ``iwe find`` and return normalized nodes.

    ``filter`` is IWE's YAML frontmatter filter (a mapping is serialized as
    JSON, which is valid YAML). Upstream marks that query language
    experimental. ``references=KEY`` selects documents that link to KEY;
    ``referenced_by=KEY`` selects documents KEY links to.
    """
    workspace = workspace_root(root)
    args = ["find"]
    if filter is not None:
        args += ["--filter", filter if isinstance(filter, str) else json.dumps(filter)]
    for key in keys:
        args += ["-k", key]
    for flag, value in (
        ("--references", references),
        ("--referenced-by", referenced_by),
        ("--includes", includes),
        ("--included-by", included_by),
        ("--lexical", lexical),
    ):
        if value is not None:
            args += [flag, value]
    if limit is not None:
        args += ["--limit", str(limit)]
    return [_node(raw) for raw in _json(args, workspace)]


def node(key: str, *, root: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """Return one document's frontmatter and graph neighbours."""
    found = find(keys=[key], root=root)
    if not found:
        raise IweError(f"no document with key {key!r}")
    return found[0]


def key_for_path(path: str | os.PathLike[str]) -> str:
    """Map a Markdown file inside a workspace to its IWE key."""
    file = Path(path).resolve()
    library = _library_root(workspace_root(file)).resolve()
    return file.relative_to(library).with_suffix("").as_posix()


def node_for_path(path: str | os.PathLike[str]) -> dict[str, Any]:
    """Return the node for a Markdown file, such as a notebook's own source."""
    return node(key_for_path(path), root=Path(path).resolve().parent)


def retrieve(
    key: str, *, depth: int = 1, root: str | os.PathLike[str] | None = None
) -> list[dict[str, Any]]:
    """Run ``iwe retrieve`` for KEY, expanding included documents to DEPTH."""
    args = ["retrieve", "-k", key, "--expand-includes", str(depth)]
    return _json(args, workspace_root(root))


def tree(
    key: str | None = None,
    *,
    depth: int = 4,
    root: str | os.PathLike[str] | None = None,
) -> Any:
    """Run ``iwe tree``, optionally rooted at KEY."""
    args = ["tree", "-d", str(depth)] + (["-k", key] if key else [])
    return _json(args, workspace_root(root))


def validate(*, root: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """Run ``iwe schema validate`` and return its JSON report."""
    workspace = workspace_root(root)
    binary = shutil.which("iwe")
    if binary is None:
        raise IweError("the iwe CLI is not on PATH")
    result = subprocess.run(
        [binary, "schema", "validate", "-f", "json"],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    report = json.loads(result.stdout) if result.stdout.strip() else {}
    return {"ok": result.returncode == 0, "report": report}
