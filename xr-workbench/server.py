"""Local XR workbench bridge. No third-party Python dependencies."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


FILES = {
    "den/aspects/xr.nix": True,
    "templates/devenv/devenv.nix": True,
    "templates/default/flake.nix": True,
    "den/inventory.nix": False,
    "flake.nix": False,
    "modules/nixos/base.nix": False,
    "docs/architecture.md": False,
}
COMMANDS = {
    "status": ["jj", "--no-pager", "status"],
    "diff": ["jj", "--no-pager", "diff", "--git"],
    "history": ["jj", "--no-pager", "log", "-n", "12"],
    "environment": [
        "nix",
        "develop",
        "path:.",
        "--command",
        "nu",
        "--no-config-file",
        "-c",
        "version",
    ],
    "evaluate": ["nix", "flake", "check", "--no-build", "path:."],
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Workbench:
    def __init__(self, repo):
        self.repo = repo.resolve()
        self.token = secrets.token_urlsafe(32)
        self.jobs = {}
        self.lock = threading.Lock()
        self.edit_lock = threading.Lock()

    def file(self, name):
        if name not in FILES:
            raise ValueError("File is not part of the workbench configuration catalog")
        path = self.repo / name
        if path.is_symlink() or not path.resolve().is_relative_to(self.repo):
            raise ValueError(
                "Configuration must be a regular file within this workspace"
            )
        return path

    def capabilities(self):
        """Describe repository-owned agent assets without claiming they are active."""
        skills_root = self.repo / ".agents" / "skills"
        skills = (
            sorted(
                path.parent.name
                for path in skills_root.glob("*/SKILL.md")
                if path.is_file() and not path.is_symlink()
            )
            if skills_root.is_dir()
            else []
        )
        ai_root = self.repo / "modules" / "tooling" / "ai"
        clients = (
            sorted(
                path.stem
                for path in ai_root.glob("*.nix")
                if path.is_file()
                and path.stem not in {"common", "plugins", "shared-skills"}
            )
            if ai_root.is_dir()
            else []
        )
        return {
            "source": "Repository inventory · configuration may differ from active runtime",
            "categories": [
                {
                    "id": "instructions",
                    "title": "Instructions",
                    "items": [
                        name
                        for name in [
                            "AGENTS.md",
                            "modules/tooling/ai/global-agent-instructions.md",
                        ]
                        if (self.repo / name).is_file()
                    ],
                },
                {"id": "skills", "title": "Skills", "items": skills},
                {"id": "clients", "title": "Clients & hooks", "items": clients},
                {
                    "id": "mcp",
                    "title": "MCP servers",
                    "items": [],
                    "note": "Runtime MCP connections are not exposed by this local bridge.",
                },
                {
                    "id": "model",
                    "title": "Model",
                    "items": [],
                    "note": "No agent runtime is connected.",
                },
            ],
        }

    def start(self, action):
        if action not in COMMANDS:
            raise ValueError("Unknown action")
        with self.lock:
            if any(j["state"] == "running" for j in self.jobs.values()):
                raise ValueError("Wait for or stop the running command first")
            ident = secrets.token_hex(6)
            job = dict(
                id=ident,
                action=action,
                command=COMMANDS[action],
                state="running",
                output="",
                exitCode=None,
            )
            self.jobs[ident] = job
            while len(self.jobs) > 20:
                del self.jobs[next(iter(self.jobs))]
        threading.Thread(target=self.run, args=(job,), daemon=True).start()
        return self.public(job)

    def public(self, job):
        return {k: v for k, v in job.items() if k != "process"}

    def run(self, job):
        try:
            process = subprocess.Popen(
                job["command"],
                cwd=self.repo,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                env={
                    **os.environ,
                    "NO_COLOR": "1",
                    "PAGER": "cat",
                    "JJ_EDITOR": "true",
                },
            )
            with self.lock:
                job["process"] = process
                cancelled = job.get("cancelled", False)
            if cancelled:
                os.killpg(process.pid, signal.SIGTERM)
            while chunk := process.stdout.read1(4096):
                with self.lock:
                    job["output"] = (job["output"] + chunk.decode(errors="replace"))[
                        -200_000:
                    ]
            code = process.wait()
            with self.lock:
                job.update(
                    exitCode=code,
                    state="stopped"
                    if job.get("cancelled")
                    else "passed"
                    if code == 0
                    else "failed",
                )
        except Exception as error:
            with self.lock:
                job.update(state="failed", output=str(error), exitCode=-1)

    def stop(self, ident):
        with self.lock:
            job = self.jobs.get(ident)
            if not job or job["state"] != "running":
                raise ValueError("No running command with that ID")
            job["cancelled"] = True
            process = job.get("process")
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return

            def kill_later():
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

            threading.Thread(target=kill_later, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data, status=200, content_type="application/json"):
        body = json.dumps(data).encode() if content_type == "application/json" else data
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        # Both loopback Host validation and an unguessable token are required.
        host = self.headers.get("Host", "")
        if host not in {
            f"localhost:{self.server.server_port}",
            f"127.0.0.1:{self.server.server_port}",
        }:
            self.reply({"error": "Use the local workbench URL"}, 403)
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        app = self.server.app
        url = urlparse(self.path)
        try:
            if url.path == "/api/session":
                self.reply(
                    dict(
                        token=app.token,
                        repo=str(app.repo),
                        files=[dict(path=k, editable=v) for k, v in FILES.items()],
                        actions=COMMANDS,
                    )
                )
            elif url.path.startswith("/api/"):
                if not secrets.compare_digest(
                    self.headers.get("X-Workbench-Token", ""), app.token
                ):
                    self.reply({"error": "Session expired; reload the page"}, 403)
                    return
                if url.path == "/api/file":
                    name = parse_qs(url.query).get("path", [""])[0]
                    data = app.file(name).read_bytes()
                    self.reply(
                        dict(
                            path=name,
                            content=data.decode(),
                            revision=digest(data),
                            editable=FILES[name],
                        )
                    )
                elif url.path == "/api/jobs":
                    with app.lock:
                        self.reply([app.public(j) for j in app.jobs.values()])
                elif url.path == "/api/capabilities":
                    self.reply(app.capabilities())
                else:
                    self.reply({"error": "Unknown endpoint"}, 404)
            else:
                self.reply({"error": "Unknown endpoint"}, 404)
        except (ValueError, OSError, UnicodeError) as error:
            self.reply({"error": str(error)}, 400)

    def do_POST(self):
        if not self.authorized():
            return
        app = self.server.app
        if not secrets.compare_digest(
            self.headers.get("X-Workbench-Token", ""), app.token
        ):
            self.reply({"error": "Invalid session"}, 403)
            return
        origin = self.headers.get("Origin")
        if origin and origin != f"http://{self.headers['Host']}":
            self.reply({"error": "Cross-origin requests are disabled"}, 403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 262144:
                raise ValueError("Request must be between 1 and 262144 bytes")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("Expected a JSON object")
            if self.path == "/api/run":
                self.reply(app.start(body.get("action", "")), 202)
            elif self.path == "/api/stop":
                app.stop(body.get("id", ""))
                self.reply({"ok": True})
            elif self.path == "/api/file":
                name = body.get("path", "")
                path = app.file(name)
                if not FILES[name]:
                    raise ValueError("This source is read-only in the workbench")
                content = body.get("content")
                if not isinstance(content, str):
                    raise ValueError("Expected text content")
                with app.edit_lock:
                    if digest(path.read_bytes()) != body.get("revision"):
                        self.reply(
                            {
                                "error": "File changed on disk. Reload it before saving; your draft is still in the editor."
                            },
                            409,
                        )
                        return
                    data = content.encode()
                    temporary = None
                    try:
                        with tempfile.NamedTemporaryFile(
                            dir=path.parent, delete=False
                        ) as handle:
                            temporary = handle.name
                            handle.write(data)
                        os.chmod(temporary, path.stat().st_mode & 0o777)
                        os.replace(temporary, path)
                    finally:
                        if temporary and os.path.exists(temporary):
                            os.unlink(temporary)
                self.reply({"revision": digest(data)})
            else:
                self.reply({"error": "Unknown endpoint"}, 404)
        except (ValueError, OSError, TypeError) as error:
            self.reply({"error": str(error)}, 400)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    if not args.repo.is_dir():
        parser.error("--repo must be a directory")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.app = Workbench(args.repo)
    print(
        f"XR Workbench → http://localhost:{server.server_port} · {args.repo.resolve()}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for ident, job in list(server.app.jobs.items()):
            if job["state"] == "running":
                server.app.stop(ident)
        server.server_close()


if __name__ == "__main__":
    main()
