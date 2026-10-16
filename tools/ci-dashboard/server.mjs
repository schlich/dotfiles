import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const HOST = "127.0.0.1";
const PORT = Number(process.env.PORT ?? 4173);
const DEFAULT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const ROOT = resolve(process.env.CI_REPO ?? DEFAULT_ROOT);
const PAGE = resolve(dirname(fileURLToPath(import.meta.url)), "index.html");
const CACHE_MS = 7_000;
const COMMAND_TIMEOUT_MS = 20_000;
const MAX_OUTPUT_BYTES = 24 * 1024 * 1024;

let cache = null;
let pending = null;

function send(
  response,
  status,
  body,
  type = "application/json; charset=utf-8",
) {
  response.writeHead(status, {
    "content-type": type,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "content-security-policy":
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  });
  response.end(body);
}

function collectTower() {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn("ci", ["tower", ".", "--json"], {
      cwd: ROOT,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    let bytes = 0;
    let settled = false;
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      fail(new Error(`ci tower exceeded ${COMMAND_TIMEOUT_MS / 1000}s`));
    }, COMMAND_TIMEOUT_MS);

    function fail(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      rejectPromise(error);
    }

    child.stdout.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > MAX_OUTPUT_BYTES) {
        child.kill("SIGTERM");
        fail(new Error("ci tower output exceeded the 24 MiB safety limit"));
        return;
      }
      stdout.push(chunk);
    });
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.once("error", (error) => fail(error));
    child.once("close", (code, signal) => {
      if (settled) return;
      clearTimeout(timeout);
      if (code !== 0) {
        const detail = Buffer.concat(stderr).toString("utf8").trim();
        fail(
          new Error(
            detail || `ci tower exited ${code ?? signal ?? "without a status"}`,
          ),
        );
        return;
      }
      try {
        const data = JSON.parse(Buffer.concat(stdout).toString("utf8"));
        if (!data || typeof data !== "object" || !data.host || !data.snapshot) {
          throw new Error(
            "ci tower returned JSON without host and snapshot data",
          );
        }
        settled = true;
        resolvePromise(data);
      } catch (error) {
        fail(new Error(`Unable to parse ci tower JSON: ${error.message}`));
      }
    });
  });
}

async function towerResponse() {
  const now = Date.now();
  if (cache && now - cache.fetchedAt < CACHE_MS) {
    return {
      snapshot: cache.data,
      fetchedAt: cache.fetchedAt,
      stale: false,
      error: null,
    };
  }
  if (!pending) {
    pending = collectTower()
      .then((data) => {
        cache = { data, fetchedAt: Date.now() };
        return cache;
      })
      .finally(() => {
        pending = null;
      });
  }
  try {
    const current = await pending;
    return {
      snapshot: current.data,
      fetchedAt: current.fetchedAt,
      stale: false,
      error: null,
    };
  } catch (error) {
    if (cache) {
      return {
        snapshot: cache.data,
        fetchedAt: cache.fetchedAt,
        stale: true,
        error: error.message,
      };
    }
    throw error;
  }
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${HOST}:${PORT}`);
  if (request.method !== "GET" && request.method !== "HEAD") {
    send(response, 405, JSON.stringify({ error: "Only GET is supported." }));
    return;
  }

  if (url.pathname === "/api/tower") {
    try {
      const body = JSON.stringify(await towerResponse());
      send(response, 200, request.method === "HEAD" ? "" : body);
    } catch (error) {
      send(
        response,
        503,
        JSON.stringify({
          snapshot: null,
          fetchedAt: null,
          stale: false,
          error: error.message,
        }),
      );
    }
    return;
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    try {
      const page = await readFile(PAGE);
      send(
        response,
        200,
        request.method === "HEAD" ? "" : page,
        "text/html; charset=utf-8",
      );
    } catch (error) {
      send(
        response,
        500,
        JSON.stringify({
          error: `Unable to read the dashboard page: ${error.message}`,
        }),
      );
    }
    return;
  }

  send(response, 404, JSON.stringify({ error: "Not found." }));
});

server.listen(PORT, HOST, () => {
  process.stdout.write(`CI dashboard listening on http://${HOST}:${PORT}\n`);
});

server.on("error", (error) => {
  process.stderr.write(`CI dashboard could not start: ${error.message}\n`);
  process.exitCode = 1;
});
