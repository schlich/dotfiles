"""Run an MCP stdio server so that clients use the 2025 handshake.

Claude Code 2.1.285 opens with `server/discover` (protocol 2026-07-28).
atuin 18.23 accepts it but then answers `tools/list` without the `ttlMs`
and `cacheScope` fields that version requires, so the client drops every
tool; atuin 18.21 does the same from `initialize`. Any request before
`initialize` also puts atuin in that mode. This wrapper answers
`server/discover` itself with "method not found", so the server never sees
it and the client falls back to `initialize` at 2025-11-25. Every other
line passes through unchanged in both directions.

Usage: mcp-legacy-handshake SERVER [ARGS...]
"""

import json
import subprocess
import sys
import threading

METHOD_NOT_FOUND = {"code": -32601, "message": "Method not found"}

lock = threading.Lock()
child = subprocess.Popen(
    sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE
)


def send(line):
    with lock:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def relay_server():
    for line in child.stdout:
        send(line)


relay = threading.Thread(target=relay_server, daemon=True)
relay.start()
for line in sys.stdin.buffer:
    try:
        message = json.loads(line)
    except ValueError:
        message = None
    if not isinstance(message, dict):
        message = {}
    if message.get("method") == "server/discover":
        if "id" in message:
            reply = {"jsonrpc": "2.0", "id": message["id"]}
            reply["error"] = METHOD_NOT_FOUND
            send(json.dumps(reply).encode() + b"\n")
        continue
    child.stdin.write(line)
    child.stdin.flush()
child.stdin.close()
code = child.wait()
relay.join()
sys.exit(code)
