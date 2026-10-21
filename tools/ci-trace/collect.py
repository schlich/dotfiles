#!/usr/bin/env python3
"""Stamp Nix json-log-path events with the time each one arrives.

Nix appends one JSON object per line to the file that its `json-log-path`
setting names, from every nix process that reads the setting, but without
timestamps. This follows that file as it grows and copies each activity
start and stop, and each build phase change, to OUT as
`<microseconds since the epoch>\t<event>`. Build log lines and progress
updates are dropped. Following a plain file rather than a FIFO means a dead
collector can never block a nix writer.

    collect.py NIX_LOG OUT

SIGTERM or SIGINT drains what is left of NIX_LOG and exits.
"""

import signal
import sys
import time

POLL_SECONDS = 0.05
KEEP = (b'"action":"start"', b'"action":"stop"')
# Result type 104 is resSetPhase: a build entering unpackPhase, buildPhase, ...
PHASE = (b'"action":"result"', b'"type":104')

stopping = False


def request_stop(_signum, _frame):
    global stopping
    stopping = True


def wanted(line):
    return any(k in line for k in KEEP) or all(k in line for k in PHASE)


def main(nix_log, out_path):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    # Create the file first, so the nix that opens it appends to ours.
    open(nix_log, "ab").close()
    with open(nix_log, "rb") as src, open(out_path, "ab") as out:
        # Marks when tracing began, so the trace's window includes
        # evaluation that logs no activity before the first query or build.
        out.write(str(time.time_ns() // 1000).encode() + b'\t{"action":"collector-start"}\n')
        out.flush()
        pending = b""
        while True:
            chunk = src.read(1 << 20)
            if chunk:
                stamp = str(time.time_ns() // 1000).encode()
                lines = (pending + chunk).split(b"\n")
                pending = lines.pop()
                for line in lines:
                    if wanted(line):
                        out.write(stamp + b"\t" + line + b"\n")
                out.flush()
                continue
            if stopping:
                return
            time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
