"""Hand nixbot's App manifest to GitHub and catch the code it returns.

nixbot-register runs this with {"manifest": ..., "state": ...} on stdin. It
listens on localhost, opens the browser on a page that posts the manifest to
GitHub's "new App" form with redirect_url pointing back here, and prints the
`code` GitHub redirects with on stdout, after checking `state`. Messages for
the person go to stderr; the request log stays off, since its query string
holds the code.
"""

import argparse
import html
import http.server
import json
import socket
import sys
import threading
import urllib.parse
import webbrowser

NEW_APP = "https://github.com/settings/apps/new"

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>nixbot-register</title>
<body onload="document.forms[0].submit()">
<form action="{action}" method="post">
<input type="hidden" name="manifest" value="{manifest}">
<p>Sending nixbot's App manifest to GitHub.
<button type="submit">Continue to GitHub</button></p>
</form>
"""

DONE = """<!doctype html>
<meta charset="utf-8">
<title>nixbot-register</title>
<p>GitHub created the App. Return to the terminal: nixbot-register stores
its secrets and opens the install page next.</p>
"""


class Server6(http.server.HTTPServer):
    address_family = socket.AF_INET6


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    request = json.load(sys.stdin)
    state = request["state"]
    caught = {}
    servers = []

    def stop():
        for server in servers:
            threading.Thread(target=server.shutdown).start()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/":
                self.reply(200, page)
            elif url.path == "/callback":
                query = urllib.parse.parse_qs(url.query)
                codes = query.get("code", [])
                if query.get("state") != [state] or len(codes) != 1:
                    self.reply(400, "<p>Not the redirect nixbot-register waits for.</p>")
                    return
                caught["code"] = codes[0]
                self.reply(200, DONE)
                stop()
            else:
                self.reply(404, "")

        def reply(self, status, body):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    servers.append(http.server.HTTPServer(("127.0.0.1", args.port), Handler))
    port = servers[0].server_port
    # Browsers may try ::1 first for localhost; answer there too when it can.
    try:
        servers.append(Server6(("::1", port), Handler))
    except OSError:
        pass

    base = f"http://localhost:{port}"
    manifest = dict(request["manifest"], redirect_url=f"{base}/callback")
    action = NEW_APP + "?" + urllib.parse.urlencode({"state": state})
    page = PAGE.format(
        action=html.escape(action), manifest=html.escape(json.dumps(manifest))
    )

    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    timer = threading.Timer(args.timeout, stop)
    timer.start()
    print(f"Opening {base}/ in the browser; open it yourself if nothing appears.",
          file=sys.stderr)
    webbrowser.open(f"{base}/")
    servers[0].serve_forever()
    timer.cancel()
    for server in servers:
        server.server_close()

    if "code" not in caught:
        print(f"GitHub did not redirect back within {args.timeout} seconds.",
              file=sys.stderr)
        sys.exit(1)
    print(caught["code"])


if __name__ == "__main__":
    main()
