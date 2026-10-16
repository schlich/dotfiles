// The dashboard's reductions of what it collects: GitHub Actions runs into
// verdicts, failed-job logs into excerpts, and a local run's log into
// line-aligned reads. server.mjs serves them; feeds.test.mjs checks them.
import { open } from "node:fs/promises";

// Lines kept from each failed step's log, ending at its last error.
export const LOG_TAIL = 15;
const LOG_TIMESTAMP = /^\d{4}-\d\d-\d\dT[\d:.]+Z ?/;
// Terminal colors, which the page replaces with its own error highlighting.
const LOG_ANSI = /\x1b\[[0-9;]*m/g;
// Substitution and download progress, which buries a Nix build's error.
const LOG_NOISE =
  /^\s*(copying path '|downloading '|these \d+ paths? will be (fetched|built)|this path will be (fetched|built)|\/nix\/store\/\S+$)/;

// A local run's log opens on its last 64 KiB, and each follow-up read returns
// at most 256 KiB, so a long build log never arrives whole.
export const JOB_LOG_WINDOW = 64 * 1024;
export const JOB_LOG_CHUNK = 256 * 1024;

export function asArray(value) {
  return Array.isArray(value) ? value : [];
}

// A feed collected at most once per `maxAgeMs`, failed attempts included,
// which keeps serving its last good data, marked stale, while collection
// fails.
export function cachedFeed(collect, maxAgeMs, now = Date.now) {
  let cache = null;
  let failure = null;
  let pending = null;
  const recent = (at) => now() - at < maxAgeMs;
  return async () => {
    if (
      !(cache && recent(cache.fetchedAt)) &&
      !(failure && recent(failure.at))
    ) {
      // An async wrapper turns a collector that throws at once into a
      // failed collection like any other.
      pending ??= (async () => collect())()
        .then(
          (data) => {
            cache = { data, fetchedAt: now() };
            failure = null;
          },
          (error) => {
            failure = {
              error: error instanceof Error ? error : new Error(String(error)),
              at: now(),
            };
          },
        )
        .finally(() => {
          pending = null;
        });
      await pending;
    }
    if (failure && !(cache && recent(cache.fetchedAt))) {
      if (!cache) throw failure.error;
      return {
        snapshot: cache.data,
        fetchedAt: cache.fetchedAt,
        stale: true,
        error: failure.error.message,
      };
    }
    return {
      snapshot: cache.data,
      fetchedAt: cache.fetchedAt,
      stale: false,
      error: null,
    };
  };
}

// GitHub Actions, reduced the way Fieldnotes' CI panel reduces them: each
// workflow's verdict on main with its failure streak, and the latest failing
// or running run of each live branch.

export function actionsRun(run, activePaths) {
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
export function summarizeActions(runs, alive) {
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
export function workflowHeader(text) {
  const comment = [];
  for (const line of text.replace(/^﻿/, "").split("\n")) {
    if (line.startsWith("#")) {
      const words = line.replace(/^#+/, "").trim();
      if (words) comment.push(words);
    } else if (comment.length || line.startsWith("jobs:")) break;
  }
  return comment.join(" ").split(". ")[0].replace(/\.$/, "");
}

// The jobs of a run that need a look (failed or still running) with their
// failed steps, failures first, and a count of the rest by conclusion. A job
// cancelled because another failed, or by a newer push, needs none.
export function summarizeJobs(data) {
  const jobs = [];
  const quiet = {};
  for (const job of asArray(data?.jobs)) {
    const conclusion = job.conclusion ?? null;
    if (["success", "skipped", "neutral", "cancelled"].includes(conclusion)) {
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
  return { jobs, quiet };
}

// Up to `tail` lines ending at the last `##[error]` marker, since the end of
// a job's log is usually cleanup; the tail when there is no marker.
export function excerpt(lines, tail = LOG_TAIL) {
  const kept = lines.filter((line) => !LOG_NOISE.test(line));
  let end = kept.length;
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    if (kept[index].includes("##[error]")) {
      end = index + 1;
      break;
    }
  }
  return kept.slice(Math.max(0, end - tail), end);
}

// `gh run view --log-failed`, grouped by job and step.
export function failedLogs(log) {
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

// The length of `bytes` without a trailing partial UTF-8 character or color
// code, unless that would leave nothing.
function wholeEnd(bytes) {
  let end = bytes.length;
  let lead = end - 1;
  while (lead > 0 && lead > end - 4 && (bytes[lead] & 0xc0) === 0x80) lead -= 1;
  const width =
    bytes[lead] >= 0xf0
      ? 4
      : bytes[lead] >= 0xe0
        ? 3
        : bytes[lead] >= 0xc0
          ? 2
          : 1;
  if (lead + width > end) end = lead;
  const escape = bytes.lastIndexOf(0x1b, end - 1);
  if (
    escape !== -1 &&
    /^\x1b(\[[0-9;]*)?$/.test(bytes.toString("latin1", escape, end))
  )
    end = escape;
  return end || bytes.length;
}

// Bytes of a local run's log from `from` on, or its last `window` when `from`
// is null. `chunk`, the most one read returns, is at least `window` and at
// least 64 bytes, room for any character or color code. A read stops at the
// last complete line, so a line still being written, or a character split
// across reads, arrives whole next time; a finished run's unterminated last
// line is returned as it is.
export async function jobLog(
  path,
  from,
  finished,
  { window = JOB_LOG_WINDOW, chunk = JOB_LOG_CHUNK } = {},
) {
  const file = await open(path, "r");
  try {
    const { size } = await file.stat();
    const opening = from === null;
    // A log that shrank was replaced; read the new one from its start.
    const start = opening ? Math.max(0, size - window) : from > size ? 0 : from;
    // An opening window also reads the byte before it, which tells whether
    // the window starts a line.
    const before = opening && start > 0 ? 1 : 0;
    const length = Math.min(chunk, size - start);
    const buffer = Buffer.alloc(before + length);
    const { bytesRead } = await file.read(
      buffer,
      0,
      before + length,
      start - before,
    );
    const read = bytesRead - before;
    let bytes = buffer.subarray(before, bytesRead);
    let skipped = 0;
    // A window that opens mid-line starts at the next line, or mid-line,
    // clipped, when no line starts within it.
    if (before && buffer[0] !== 0x0a) {
      const first = bytes.indexOf(0x0a);
      if (first !== -1 && first + 1 < bytes.length) {
        skipped = first + 1;
        bytes = bytes.subarray(skipped);
      }
    }
    const atEnd = start + read >= size;
    if (!(finished && atEnd)) {
      const last = bytes.lastIndexOf(0x0a);
      if (last !== -1) bytes = bytes.subarray(0, last + 1);
      else if (read < chunk) bytes = bytes.subarray(0, 0);
      // A line longer than a chunk arrives in pieces of whole characters.
      else bytes = bytes.subarray(0, wholeEnd(bytes));
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
