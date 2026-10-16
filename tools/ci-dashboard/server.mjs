import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  actionsRun,
  asArray,
  cachedFeed,
  failedLogs,
  jobLog,
  summarizeActions,
  summarizeJobs,
  workflowHeader,
} from "./feeds.mjs";

const HOST = "127.0.0.1";
const PORT = Number(process.env.PORT ?? 4173);
const DEFAULT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const ROOT = resolve(process.env.CI_REPO ?? DEFAULT_ROOT);
const PAGE = resolve(dirname(fileURLToPath(import.meta.url)), "index.html");
const GITHUB_REPO = process.env.CI_GITHUB_REPO ?? "schlich/dotfiles";
const CACHE_MS = 7_000;
// Fieldnotes polls GitHub every 30 seconds too, which keeps both well inside
// the API's hourly limit.
const ACTIONS_CACHE_MS = 30_000;
const COMMAND_TIMEOUT_MS = 20_000;
const LOG_TIMEOUT_MS = 45_000;
const MAX_OUTPUT_BYTES = 24 * 1024 * 1024;

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

function capture(command, args, timeoutMs = COMMAND_TIMEOUT_MS) {
  const name = `${command} ${args[0]}`;
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: ROOT,
      env: {
        ...process.env,
        GH_NO_UPDATE_NOTIFIER: "1",
        GH_PROMPT_DISABLED: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    let bytes = 0;
    let settled = false;
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      fail(new Error(`${name} exceeded ${timeoutMs / 1000}s`));
    }, timeoutMs);

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
        fail(new Error(`${name} output exceeded the 24 MiB safety limit`));
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
            detail || `${name} exited ${code ?? signal ?? "without a status"}`,
          ),
        );
        return;
      }
      settled = true;
      resolvePromise(Buffer.concat(stdout).toString("utf8"));
    });
  });
}

async function captureJSON(command, args, timeoutMs) {
  const text = await capture(command, args, timeoutMs);
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(
      `Unable to parse ${command} ${args[0]} JSON: ${error.message}`,
    );
  }
}

async function collectTower() {
  const data = await captureJSON("ci", ["tower", ".", "--json"]);
  if (!data || typeof data !== "object" || !data.host || !data.snapshot) {
    throw new Error("ci tower returned JSON without host and snapshot data");
  }
  return data;
}

function gh(path, timeoutMs) {
  return captureJSON("gh", ["api", path], timeoutMs);
}

// Workflow path -> { sha, about }.
const aboutCache = new Map();

async function workflowAbout(path, sha) {
  // Dependabot and Copilot runs have no file in the repository.
  if (!path.startsWith(".github/workflows/")) return "managed by GitHub";
  const cached = aboutCache.get(path);
  if (cached && cached.sha === sha) return cached.about;
  try {
    const data = await gh(`repos/${GITHUB_REPO}/contents/${path}?ref=${sha}`);
    const about = workflowHeader(
      Buffer.from(data?.content ?? "", "base64").toString("utf8"),
    );
    aboutCache.set(path, { sha, about });
    return about;
  } catch {
    return cached?.about ?? "";
  }
}

// Run id and attempt -> jobs of a finished run, which no longer change.
const jobsCache = new Map();

async function runJobs(run) {
  const key = `${run.id}/${run.attempt}`;
  if (jobsCache.has(key)) return jobsCache.get(key);
  const result = summarizeJobs(
    await gh(`repos/${GITHUB_REPO}/actions/runs/${run.id}/jobs?per_page=100`),
  );
  if (run.status === "completed") jobsCache.set(key, result);
  return result;
}

async function liveBranches() {
  try {
    const names = await capture("gh", [
      "api",
      "--paginate",
      `repos/${GITHUB_REPO}/branches?per_page=100`,
      "--jq",
      ".[].name",
    ]);
    return new Set(names.split(/\s+/).filter(Boolean));
  } catch {
    return null;
  }
}

async function collectActions() {
  const [runsData, workflowsData, alive] = await Promise.all([
    gh(`repos/${GITHUB_REPO}/actions/runs?per_page=40`),
    gh(`repos/${GITHUB_REPO}/actions/workflows`),
    liveBranches(),
  ]);
  const active = new Set(
    asArray(workflowsData?.workflows)
      .filter((workflow) => workflow.state === "active")
      .map((workflow) => workflow.path),
  );
  const runs = asArray(runsData?.workflow_runs).map((run) =>
    actionsRun(run, active),
  );
  const state = summarizeActions(runs, alive);
  await Promise.all([
    ...state.main.map(async (verdict) => {
      verdict.about = await workflowAbout(
        verdict.run.path,
        verdict.run.sha || "main",
      );
    }),
    // Only failing and running runs show their jobs, as in Fieldnotes.
    ...[...state.main.map((verdict) => verdict.run), ...state.branches]
      .filter((run) => ["failed", "running"].includes(run.state) && run.id)
      .map(async (run) => {
        try {
          Object.assign(run, await runJobs(run));
        } catch (error) {
          run.jobsError = error.message;
        }
      }),
  ]);
  return { repo: GITHUB_REPO, ...state };
}

// Run id -> failed-step excerpts; a failed run's log never changes.
const logCache = new Map();

async function runLog(id) {
  if (logCache.has(id)) return logCache.get(id);
  const log = await capture(
    "gh",
    ["run", "view", id, "-R", GITHUB_REPO, "--log-failed"],
    LOG_TIMEOUT_MS,
  );
  const steps = failedLogs(log);
  logCache.set(id, steps);
  return steps;
}

const towerResponse = cachedFeed(collectTower, CACHE_MS);
const actionsResponse = cachedFeed(collectActions, ACTIONS_CACHE_MS);

async function sendFeed(request, response, feed) {
  try {
    const body = JSON.stringify(await feed());
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
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${HOST}:${PORT}`);
  if (request.method !== "GET" && request.method !== "HEAD") {
    send(response, 405, JSON.stringify({ error: "Only GET is supported." }));
    return;
  }

  if (url.pathname === "/api/tower") {
    await sendFeed(request, response, towerResponse);
    return;
  }

  if (url.pathname === "/api/actions") {
    await sendFeed(request, response, actionsResponse);
    return;
  }

  if (url.pathname === "/api/actions/log") {
    const id = url.searchParams.get("run") ?? "";
    if (!/^\d+$/.test(id)) {
      send(response, 400, JSON.stringify({ error: "Expected a numeric run." }));
      return;
    }
    try {
      const body = JSON.stringify({ steps: await runLog(id), error: null });
      send(response, 200, request.method === "HEAD" ? "" : body);
    } catch (error) {
      send(response, 502, JSON.stringify({ steps: [], error: error.message }));
    }
    return;
  }

  // A local run's log, named by run id: only paths the tower snapshot lists
  // are ever read.
  if (url.pathname === "/api/runs/log") {
    const id = url.searchParams.get("run") ?? "";
    const fromParam = url.searchParams.get("from");
    const from = fromParam === null ? null : Number(fromParam);
    if (!id || (from !== null && !(Number.isInteger(from) && from >= 0))) {
      send(
        response,
        400,
        JSON.stringify({ error: "Expected a run id and a byte offset." }),
      );
      return;
    }
    try {
      const tower = await towerResponse();
      const run = asArray(tower.snapshot?.runs).find(
        (entry) => entry.id === id,
      );
      if (!run?.log) {
        send(
          response,
          404,
          JSON.stringify({ error: `No log is known for run ${id}.` }),
        );
        return;
      }
      const finished = !["running", "working", "blocked", "queued"].includes(
        String(run.state),
      );
      const body = JSON.stringify({
        id,
        path: run.log,
        state: run.state,
        finished,
        ...(await jobLog(run.log, from, finished)),
        error: null,
      });
      send(response, 200, request.method === "HEAD" ? "" : body);
    } catch (error) {
      send(response, 502, JSON.stringify({ text: "", error: error.message }));
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
