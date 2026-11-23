import http from "node:http";
import { spawn } from "node:child_process";

const host = process.env.KB_GIT_HOST || "127.0.0.1";
const port = Number(process.env.KB_GIT_PORT || "8792");
const projectRoot = process.env.KB_GIT_PROJECT_ROOT;
const gitHttpBackend = process.env.KB_GIT_BACKEND || "git-http-backend";
const onPushBin = process.env.KB_GIT_ON_PUSH || "";
const onPushArgs = process.env.KB_GIT_ON_PUSH_ARGS
  ? JSON.parse(process.env.KB_GIT_ON_PUSH_ARGS)
  : [];
const requireTailscaleHeader = process.env.KB_GIT_ALLOW_INSECURE_LOCAL !== "1";

if (!projectRoot) {
  console.error("kb-git: KB_GIT_PROJECT_ROOT is required");
  process.exit(1);
}

const allowedPaths = new Set([
  "/kb.git/HEAD",
  "/kb.git/info/refs",
  "/kb.git/git-upload-pack",
  "/kb.git/git-receive-pack",
]);

function findHeaderSplit(buf) {
  const crlf = buf.indexOf("\r\n\r\n");
  if (crlf !== -1) return { index: crlf, sepLen: 4 };
  const lf = buf.indexOf("\n\n");
  if (lf !== -1) return { index: lf, sepLen: 2 };
  return null;
}

function triggerOnPush() {
  if (!onPushBin) return;
  const child = spawn(onPushBin, onPushArgs, {
    detached: true,
    stdio: "ignore",
    env: process.env,
  });
  child.on("error", (err) => {
    console.error(`kb-git: on-push hook failed to start: ${err.message}`);
  });
  child.unref();
}

const server = http.createServer((req, res) => {
  const identity = req.headers["tailscale-user-login"];
  const remoteUser = Array.isArray(identity) ? identity[0] : identity;
  if (requireTailscaleHeader && !remoteUser) {
    res.writeHead(403, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Reach kb-git through Tailscale Serve.\n");
    return;
  }

  let parsed;
  try {
    parsed = new URL(req.url || "/", "http://127.0.0.1");
  } catch {
    res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Bad request\n");
    return;
  }

  if (!allowedPaths.has(parsed.pathname)) {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Not found\n");
    return;
  }

  const isReceivePack =
    req.method === "POST" && parsed.pathname === "/kb.git/git-receive-pack";

  const cgiEnv = {
    PATH: process.env.PATH || "",
    HOME: process.env.HOME || "",
    GIT_PROJECT_ROOT: projectRoot,
    GIT_HTTP_EXPORT_ALL: "1",
    PATH_INFO: parsed.pathname,
    QUERY_STRING: parsed.search ? parsed.search.slice(1) : "",
    REQUEST_METHOD: req.method || "GET",
    REMOTE_USER: remoteUser || "local-test",
    REMOTE_ADDR: req.socket.remoteAddress || "127.0.0.1",
    SERVER_PROTOCOL: `HTTP/${req.httpVersion}`,
    CONTENT_TYPE: req.headers["content-type"] || "",
  };
  if (req.headers["content-length"] !== undefined) {
    cgiEnv.CONTENT_LENGTH = String(req.headers["content-length"]);
  }
  if (req.headers["content-encoding"] !== undefined) {
    cgiEnv.HTTP_CONTENT_ENCODING = String(req.headers["content-encoding"]);
  }
  if (req.headers["git-protocol"] !== undefined) {
    cgiEnv.HTTP_GIT_PROTOCOL = String(req.headers["git-protocol"]);
  }

  const child = spawn(gitHttpBackend, [], {
    env: cgiEnv,
    stdio: ["pipe", "pipe", "pipe"],
  });

  req.pipe(child.stdin);
  child.stdin.on("error", () => {});

  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString("utf8");
  });

  let headerChunks = [];
  let headersSent = false;
  let responseStatus = 200;

  child.stdout.on("data", (chunk) => {
    if (headersSent) {
      res.write(chunk);
      return;
    }
    headerChunks.push(chunk);
    const combined = Buffer.concat(headerChunks);
    const split = findHeaderSplit(combined);
    if (!split) return;

    headersSent = true;
    const rawHeaders = combined.subarray(0, split.index).toString("latin1");
    const rest = combined.subarray(split.index + split.sepLen);
    headerChunks = [];

    let statusCode = 200;
    const outHeaders = {};
    for (const line of rawHeaders.split(/\r?\n/)) {
      if (!line) continue;
      const colon = line.indexOf(":");
      if (colon === -1) continue;
      const name = line.slice(0, colon).trim();
      const value = line.slice(colon + 1).trim();
      if (name.toLowerCase() === "status") {
        const parsedCode = Number.parseInt(value.split(/\s+/)[0], 10);
        if (Number.isFinite(parsedCode)) statusCode = parsedCode;
      } else {
        const key = name.toLowerCase();
        if (outHeaders[key] === undefined) {
          outHeaders[key] = value;
        } else if (Array.isArray(outHeaders[key])) {
          outHeaders[key].push(value);
        } else {
          outHeaders[key] = [outHeaders[key], value];
        }
      }
    }

    responseStatus = statusCode;
    res.writeHead(statusCode, outHeaders);
    if (rest.length > 0) res.write(rest);
  });

  child.on("error", (err) => {
    console.error(`kb-git: failed to run ${gitHttpBackend}: ${err.message}`);
    if (!headersSent) {
      res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    }
    res.end("Internal server error\n");
  });

  child.on("close", (code) => {
    if (stderr.trim()) {
      console.error(`kb-git: git-http-backend stderr: ${stderr.trim()}`);
    }
    if (!headersSent) {
      res.writeHead(code === 0 ? 204 : 500, {
        "Content-Type": "text/plain; charset=utf-8",
      });
    }
    res.end();
    if (isReceivePack && code === 0 && responseStatus < 400) {
      triggerOnPush();
    }
  });
});

server.listen(port, host, () => {
  const addr = server.address();
  const actualPort = typeof addr === "object" && addr ? addr.port : port;
  console.log(`kb-git listening on http://${host}:${actualPort}`);
});
