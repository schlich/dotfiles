import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { open, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

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

// Lines kept from each failed step's log, ending at its last error.
const LOG_TAIL = 15;
const LOG_TIMESTAMP = /^\d{4}-\d\d-\d\dT[\d:.]+Z ?/;
// Terminal colors, which the page replaces with its own error highlighting.
const LOG_ANSI = /\x1b\[[0-9;]*m/g;
// Substitution and download progress, which buries a Nix build's error.
const LOG_NOISE =
  /^\s*(copying path '|downloading '|these \d+ paths? will be (fetched|built)|this path will be (fetched|built)|\/nix\/store\/\S+$)/;

// A local run's log opens on its last 64 KiB, and each follow-up read returns
// at most 256 KiB, so a long build log never arrives whole.
const JOB_LOG_WINDOW = 64 * 1024;
const JOB_LOG_CHUNK = 256 * 1024;

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

// A feed collected at most once per `maxAgeMs`, which keeps serving its last
// good data, marked stale, while collection fails.
function cachedFeed(collect, maxAgeMs) {
  let cache = null;
  let pending = null;
  return async () => {
    if (cache && Date.now() - cache.fetchedAt < maxAgeMs) {
      return {
        snapshot: cache.data,
        fetchedAt: cache.fetchedAt,
        stale: false,
        error: null,
      };
    }
    if (!pending) {
      pending = collect()
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
  };
}

// GitHub Actions, reduced the way Fieldnotes' CI panel reduces them: each
// workflow's verdict on main with its failure streak, and the latest failing
// or running run of each live branch.

function gh(path, timeoutMs) {
  return captureJSON("gh", ["api", path], timeoutMs);
}

function actionsRun(run, activePaths) {
  const path = run.path || "";
  const status = run.status || "";
  const conclusion = run.conclusion ?? null;
  let state = "failed";
  if (status !== "completed") state = "running";
  else if (conclusion === "success") state = "passed";
  else if (["cancelled", "skipped", "neutral"].includes(conclusion))
    state = "skipped";
  return {
    id: run.id || 0,
    workflow: run.name || "workflow",
    title: run.display_title || "",
    status,
    conclusion,
    state,
    created: run.created_at || null,
    branch: run.head_branch || "",
    sha: run.head_sha || "",
    path,
    url: run.html_url || "",
    number: run.run_number || 0,
    attempt: run.run_attempt || 1,
    event: run.event || "",
    // GitHub stops listing a workflow once its file leaves the default
    // branch, but keeps showing that workflow's old runs.
    retired: !activePaths.has(path),
  };
}

// Superseded (cancelled) runs are ignored, since a newer push replaced them,
// and so are runs on deleted branches, which nobody can fix any more.
// `alive` of `null` keeps every branch.
function summarizeActions(runs, alive) {
  const history = new Map();
  const branches = new Map();
  for (const run of runs) {
    if (run.state === "skipped") continue;
    if (run.branch === "main") {
      if (!history.has(run.workflow)) history.set(run.workflow, []);
      history.get(run.workflow).push(run);
    } else {
      const key = `${run.workflow}\0${run.branch}`;
      if (!branches.has(key)) branches.set(key, run);
    }
  }
  const order = { failed: 0, running: 1, passed: 2 };
  const main = [...history.entries()]
    .map(([workflow, mainRuns]) => {
      const latest = mainRuns[0];
      let streak = 0;
      while (streak < mainRuns.length && mainRuns[streak].state === "failed")
        streak += 1;
      return {
        workflow,
        // A workflow removed from main never runs again, so its last verdict
        // is history rather than something to fix.
        state: latest.retired ? "retired" : latest.state,
        streak,
        streakOpen: streak === mainRuns.length,
        about: "",
        run: latest,
      };
    })
    .sort((a, b) => (order[a.state] ?? 3) - (order[b.state] ?? 3));
  const others = [...branches.values()].filter(
    (run) =>
      ["failed", "running"].includes(run.state) &&
      !run.retired &&
      (alive === null || alive.has(run.branch)),
  );
  return { main, branches: others };
}

// The first sentence of a workflow file's top-level header comment.
function workflowHeader(text) {
  const comment = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("#")) comment.push(line.replace(/^#+/, "").trim());
    else if (comment.length || line.startsWith("jobs:")) break;
  }
  return comment.join(" ").split(". ")[0].replace(/\.$/, "");
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

// The jobs that need a look (failed or still running) with their failed
// steps, and a count of the rest by conclusion.
async function runJobs(run) {
  const key = `${run.id}/${run.attempt}`;
  if (jobsCache.has(key)) return jobsCache.get(key);
  const data = await gh(
    `repos/${GITHUB_REPO}/actions/runs/${run.id}/jobs?per_page=100`,
  );
  const jobs = [];
  const quiet = {};
  for (const job of asArray(data?.jobs)) {
    const conclusion = job.conclusion ?? null;
    if (["success", "skipped", "neutral"].includes(conclusion)) {
      quiet[conclusion] = (quiet[conclusion] ?? 0) + 1;
      continue;
    }
    jobs.push({
      name: job.name || "job",
      conclusion,
      started: job.started_at || null,
      completed: job.completed_at || null,
      url: job.html_url || "",
      failedSteps: asArray(job.steps)
        .filter((step) => step.conclusion === "failure")
        .map((step) => step.name),
    });
  }
  const failing = ["failure", "timed_out", "startup_failure"];
  jobs.sort(
    (a, b) =>
      Number(!failing.includes(a.conclusion)) -
      Number(!failing.includes(b.conclusion)),
  );
  const result = { jobs, quiet };
  if (run.status === "completed") jobsCache.set(key, result);
  return result;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
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

// Up to `LOG_TAIL` lines ending at the last `##[error]` marker, since the
// end of a job's log is usually cleanup; the tail when there is no marker.
function excerpt(lines) {
  const kept = lines.filter((line) => !LOG_NOISE.test(line));
  let end = kept.length;
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    if (kept[index].includes("##[error]")) {
      end = index + 1;
      break;
    }
  }
  return kept.slice(Math.max(0, end - LOG_TAIL), end);
}

// `gh run view --log-failed`, grouped by job and step.
function failedLogs(log) {
  const groups = new Map();
  for (const line of log.split("\n")) {
    if (!line) continue;
    const [job = "", step = "", ...rest] = line.split("\t");
    const key = `${job}\0${step}`;
    if (!groups.has(key)) groups.set(key, { job, step, lines: [] });
    groups
      .get(key)
      .lines.push(
        rest.join("\t").replace(LOG_TIMESTAMP, "").replace(LOG_ANSI, ""),
      );
  }
  return [...groups.values()].map((group) => ({
    ...group,
    lines: excerpt(group.lines),
  }));
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

// Bytes of a local run's log from `from` on, or its last `JOB_LOG_WINDOW` when
// `from` is absent. A read stops at the last complete line, so a line still
// being written, or a character split across reads, arrives whole next time;
// a finished run's unterminated last line is returned as it is.
async function jobLog(path, from, finished) {
  const file = await open(path, "r");
  try {
    const { size } = await file.stat();
    // A log that shrank was replaced; read the new one from its start.
    let start = from === null || from > size ? null : from;
    const opening = start === null;
    if (opening) start = Math.max(0, size - JOB_LOG_WINDOW);
    const length = Math.min(JOB_LOG_CHUNK, size - start);
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await file.read(buffer, 0, length, start);
    let bytes = buffer.subarray(0, bytesRead);
    let skipped = 0;
    // A window that opens mid-line starts at the next one.
    if (opening && start > 0) {
      const first = bytes.indexOf(0x0a);
      skipped = first === -1 ? bytes.length : first + 1;
      bytes = bytes.subarray(skipped);
    }
    const atEnd = start + bytesRead >= size;
    if (!(finished && atEnd)) {
      const last = bytes.lastIndexOf(0x0a);
      if (last !== -1) bytes = bytes.subarray(0, last + 1);
      else if (bytesRead < JOB_LOG_CHUNK) bytes = bytes.subarray(0, 0);
    }
    return {
      text: bytes.toString("utf8").replace(LOG_ANSI, ""),
      from: start + skipped,
      next: start + skipped + bytes.length,
      size,
      clipped: start + skipped > 0 && opening,
    };
  } finally {
    await file.close();
  }
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
