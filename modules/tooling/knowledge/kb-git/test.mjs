import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const serverScript = process.argv[2];
const kbSyncScript = process.argv[3];
assert(serverScript, "usage: test.mjs <server.mjs> <kb-sync.nu>");
assert(kbSyncScript, "usage: test.mjs <server.mjs> <kb-sync.nu>");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "kb-git-test-"));
let serverProc;
let proxyServer;

const testHome = path.join(tmp, "home");
fs.mkdirSync(testHome, { recursive: true });
const testEnv = { ...process.env, HOME: testHome };
delete testEnv.JJ_CONFIG;
delete testEnv.GIT_CONFIG_GLOBAL;

async function execClean(cmd, args) {
  await execFileAsync(cmd, args, { env: testEnv, timeout: 30_000 });
}

async function runNu(...args) {
  await execClean("nu", ["--no-config-file", kbSyncScript, ...args]);
}

try {
  const projectRoot = path.join(tmp, "Research");
  const bare = path.join(projectRoot, "kb.git");
  const asus = path.join(tmp, "asus-kb");
  const homelab = path.join(tmp, "homelab-kb");
  const pushMarker = path.join(tmp, "pushed");
  fs.mkdirSync(projectRoot, { recursive: true });
  await execClean("git", ["init", "--bare", "--initial-branch=main", bare]);

  // Start kb-git on an ephemeral port with Tailscale-User-Login enforcement on.
  serverProc = spawn(process.execPath, [serverScript], {
    env: {
      ...testEnv,
      KB_GIT_HOST: "127.0.0.1",
      KB_GIT_PORT: "0",
      KB_GIT_PROJECT_ROOT: projectRoot,
      KB_GIT_ON_PUSH: process.execPath,
      KB_GIT_ON_PUSH_ARGS: JSON.stringify([
        "-e",
        `require("node:fs").writeFileSync(${JSON.stringify(pushMarker)}, "ok\\n")`,
      ]),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  const backendPort = await new Promise((resolve, reject) => {
    let buf = "";
    serverProc.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const m = buf.match(/http:\/\/127\.0\.0\.1:(\d+)/);
      if (m) resolve(Number(m[1]));
    });
    serverProc.stderr.on("data", (chunk) => process.stderr.write(chunk));
    serverProc.on("exit", (code) => reject(new Error(`server exited ${code}`)));
  });

  // 1. Direct request without Tailscale-User-Login must be rejected with 403.
  const unauthStatus = await new Promise((resolve, reject) => {
    http
      .get(
        `http://127.0.0.1:${backendPort}/kb.git/info/refs?service=git-upload-pack`,
        (res) => {
          res.resume();
          resolve(res.statusCode);
        },
      )
      .on("error", reject);
  });
  assert.equal(unauthStatus, 403, "expected 403 without Tailscale-User-Login");

  // 2. Unknown path with Tailscale header must return 404.
  const badPathStatus = await new Promise((resolve, reject) => {
    http
      .get(
        `http://127.0.0.1:${backendPort}/other.git/info/refs`,
        { headers: { "Tailscale-User-Login": "schlich@github" } },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        },
      )
      .on("error", reject);
  });
  assert.equal(badPathStatus, 404, "expected 404 for sibling repo path");

  // 3. Simulate Tailscale Serve injecting Tailscale-User-Login in front of kb-git.
  proxyServer = http.createServer((req, res) => {
    const upstream = http.request(
      {
        host: "127.0.0.1",
        port: backendPort,
        method: req.method,
        path: req.url,
        headers: {
          ...req.headers,
          "tailscale-user-login": "schlich@github",
        },
      },
      (upRes) => {
        res.writeHead(upRes.statusCode || 500, upRes.headers);
        upRes.pipe(res);
      },
    );
    upstream.on("error", (err) => {
      if (!res.headersSent) res.writeHead(502);
      res.end(err.message);
    });
    req.pipe(upstream);
  });
  const proxyPort = await new Promise((resolve) => {
    proxyServer.listen(0, "127.0.0.1", () =>
      resolve(proxyServer.address().port),
    );
  });
  const remoteUrl = `http://127.0.0.1:${proxyPort}/kb.git`;

  // 4. Create a local-only non-colocated JJ repo on asus with an already-committed
  //    note at @- and empty @ (no origin remote, no main bookmark yet).
  fs.mkdirSync(asus, { recursive: true });
  await execClean("jj", ["--no-pager", "git", "init", asus]);
  await execClean("jj", [
    "--no-pager",
    "-R",
    asus,
    "config",
    "set",
    "--repo",
    "user.name",
    "Test User",
  ]);
  await execClean("jj", [
    "--no-pager",
    "-R",
    asus,
    "config",
    "set",
    "--repo",
    "user.email",
    "test@example.com",
  ]);
  fs.writeFileSync(
    path.join(asus, "index.md"),
    "# Index\nfrom asus over tailscale\n",
  );
  await execClean("jj", [
    "--no-pager",
    "-R",
    asus,
    "commit",
    "-m",
    "initial note",
  ]);

  // asus predates the Tailscale remote: its origin still points elsewhere.
  const staleBare = path.join(tmp, "stale.git");
  await execClean("git", ["init", "--bare", "--initial-branch=main", staleBare]);
  await execClean("jj", [
    "--no-pager",
    "-R",
    asus,
    "git",
    "remote",
    "add",
    "origin",
    staleBare,
  ]);

  // First sync replaces the stale origin with --remote-url and seeds main from @-.
  await runNu(
    "--root",
    asus,
    "--remote-url",
    remoteUrl,
    "--manual",
    "--host",
    "asus",
  );

  const { stdout: remoteList } = await execFileAsync(
    "jj",
    ["--no-pager", "-R", asus, "git", "remote", "list"],
    { env: testEnv },
  );
  const remotes = Object.fromEntries(
    remoteList
      .trim()
      .split("\n")
      .map((l) => l.trim().split(/\s+/)),
  );
  assert.equal(remotes.origin, remoteUrl, "origin should be the configured URL");
  assert.equal(remotes["origin-old"], staleBare, "stale origin kept as origin-old");

  // Verify on-push hook fired.
  for (let i = 0; i < 40 && !fs.existsSync(pushMarker); i++) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert(
    fs.existsSync(pushMarker),
    "expected KB_GIT_ON_PUSH hook to fire after git-receive-pack",
  );

  // 5. homelab does not exist yet: kb-sync --fetch-only --remote-url auto-clones it.
  await runNu(
    "--root",
    homelab,
    "--remote-url",
    remoteUrl,
    "--fetch-only",
    "--host",
    "homelab",
  );
  assert.equal(
    fs.readFileSync(path.join(homelab, "index.md"), "utf8"),
    "# Index\nfrom asus over tailscale\n",
  );

  // 6. Configure user identity on homelab (like wrapped jj in user sessions)
  //    without touching @'s empty author from the system-service clone, then write and push.
  await execClean("jj", [
    "--no-pager",
    "-R",
    homelab,
    "config",
    "set",
    "--repo",
    "user.name",
    "Test User",
  ]);
  await execClean("jj", [
    "--no-pager",
    "-R",
    homelab,
    "config",
    "set",
    "--repo",
    "user.email",
    "test@example.com",
  ]);
  fs.writeFileSync(path.join(homelab, "homelab.md"), "# From Homelab\n");
  await runNu(
    "--root",
    homelab,
    "--remote-url",
    remoteUrl,
    "--manual",
    "--host",
    "homelab",
  );
  await runNu(
    "--root",
    asus,
    "--remote-url",
    remoteUrl,
    "--fetch-only",
    "--host",
    "asus",
  );
  assert.equal(
    fs.readFileSync(path.join(asus, "homelab.md"), "utf8"),
    "# From Homelab\n",
  );

  console.log("kb-git-test: all cases passed");
} finally {
  if (proxyServer) proxyServer.close();
  if (serverProc) serverProc.kill();
  fs.rmSync(tmp, { recursive: true, force: true });
}
