// Hegel properties for feeds.mjs, one contract per test. Run with
// `node --test` in this directory after `npm ci`; the flake check
// ci-dashboard-feeds runs the same suite.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import * as hegel from "@hegeldev/hegel";
import * as gs from "@hegeldev/hegel/generators";
import {
  actionsRun,
  asArray,
  cachedFeed,
  excerpt,
  failedLogs,
  JOB_LOG_CHUNK,
  JOB_LOG_WINDOW,
  jobLog,
  LOG_TAIL,
  summarizeActions,
  summarizeJobs,
  workflowHeader,
} from "./feeds.mjs";

const MANY = { testCases: 2000 };
// Each case of these writes a file.
const FILES = { testCases: 1000 };

const dir = mkdtempSync(join(tmpdir(), "ci-dashboard-feeds-"));
const logPath = join(dir, "run.log");
after(() => rmSync(dir, { recursive: true, force: true }));

// Terminal colors (SGR sequences), which every read removes.
const SGR = /\x1b\[[0-9;]*m/g;
const decoded = (bytes) => bytes.toString("utf8").replace(SGR, "");

// --- jobLog ------------------------------------------------------------------

// Build-log text: Unicode runs, both newline conventions, terminal colors,
// multi-byte characters, and NUL, in any order.
const logPiece = gs.oneOf(
  gs.text({ maxSize: 12 }),
  gs.sampledFrom([
    "\n",
    "\n",
    "\r\n",
    "\x1b[31m",
    "\x1b[0m",
    "\x1b[1;32m",
    "é",
    "日本語",
    "🦀",
    "\0",
    "##[error] build failed",
  ]),
  // Lines longer than a chunk, of characters and color codes that a chunk
  // boundary can split.
  gs
    .tuples(
      gs.sampledFrom(["é", "日本語", "🦀", "\x1b[1;32m", "a"]),
      gs.integers({ minValue: 1, maxValue: 200 }),
    )
    .map(([piece, count]) => piece.repeat(count)),
);
const logText = gs.arrays(logPiece).map((pieces) => pieces.join(""));
// Any bytes at all, valid UTF-8 or not.
const logBytes = gs.oneOf(
  logText.map((text) => Buffer.from(text, "utf8")),
  gs.binary().map((bytes) => Buffer.from(bytes)),
);

// A window and chunk for a log of `size` bytes, as jobLog documents them: the
// chunk at least the window and at least 64 bytes. Larger values read the
// same as these largest ones.
function drawKnobs(tc, size) {
  const window = tc.draw(gs.integers({ minValue: 1, maxValue: size + 2 }));
  const least = Math.max(window, 64);
  const chunk = tc.draw(
    gs.integers({ minValue: least, maxValue: least + size + 2 }),
  );
  return { window, chunk };
}

// Where an opening read starts: the first line that starts within the last
// window, or the window's start when none does.
function openingFrom(bytes, window) {
  const start = Math.max(0, bytes.length - window);
  for (let offset = start; offset < bytes.length; offset += 1) {
    if (startsLine(bytes, offset)) return offset;
  }
  return start;
}

function drawLog(tc) {
  const bytes = tc.draw(logBytes);
  writeFileSync(logPath, bytes);
  return bytes;
}

const startsLine = (bytes, offset) =>
  offset === 0 || bytes[offset - 1] === 0x0a;

// Reads the log the way the page follows it: the opening read, then from each
// read's `next` until one makes no progress.
async function follow(bytes, finished, options) {
  const reads = [await jobLog(logPath, null, finished, options)];
  for (;;) {
    const last = reads.at(-1);
    const read = await jobLog(logPath, last.next, finished, options);
    if (read.next === last.next) return reads;
    reads.push(read);
    if (reads.length > bytes.length + 2) {
      throw new Error(`reads kept advancing past ${bytes.length} bytes`);
    }
  }
}

test("a log read returns exactly the file's bytes between its from and next", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const from = tc.draw(
      gs.oneOf(
        gs.just(null),
        gs.integers({ minValue: 0, maxValue: bytes.length }),
        gs.integers({ minValue: bytes.length + 1 }),
      ),
    );
    const finished = tc.draw(gs.booleans());
    const read = await jobLog(logPath, from, finished, options);
    assert.equal(read.size, bytes.length);
    assert.ok(
      0 <= read.from && read.from <= read.next && read.next <= read.size,
    );
    assert.equal(read.text, decoded(bytes.subarray(read.from, read.next)));
  }, FILES));

test("a follow-up read starts where it was asked to", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const from = tc.draw(gs.integers({ minValue: 0, maxValue: bytes.length }));
    const read = await jobLog(logPath, from, tc.draw(gs.booleans()), options);
    assert.equal(read.from, from);
    assert.equal(read.clipped, false);
  }, FILES));

test("a read stops at a line end unless no line ends within a chunk", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const from = tc.draw(gs.integers({ minValue: 0, maxValue: bytes.length }));
    const finished = tc.draw(gs.booleans());
    const read = await jobLog(logPath, from, finished, options);
    const finishedLine = finished && read.next === bytes.length;
    const ahead = bytes.subarray(from, from + options.chunk);
    const longLine = ahead.length === options.chunk && !ahead.includes(0x0a);
    assert.ok(
      startsLine(bytes, read.next) ||
        read.next === read.from ||
        finishedLine ||
        longLine,
      `read [${read.from}, ${read.next}) of ${bytes.length} ends mid-line`,
    );
  }, FILES));

test("a read's text holds no color codes", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const from = tc.draw(
      gs.optional(gs.integers({ minValue: 0, maxValue: bytes.length })),
    );
    const read = await jobLog(logPath, from, tc.draw(gs.booleans()), options);
    assert.doesNotMatch(read.text, /\x1b\[[0-9;]*m/);
  }, FILES));

test("an opening read starts at the first line within the last window", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const read = await jobLog(logPath, null, tc.draw(gs.booleans()), options);
    assert.equal(read.from, openingFrom(bytes, options.window));
  }, FILES));

test("an opening read is clipped exactly when it starts after the log's start", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const read = await jobLog(logPath, null, tc.draw(gs.booleans()), options);
    assert.equal(read.clipped, read.from > 0);
  }, FILES));

// The page clears its view when `from` moves back, and shows a clipped note
// only on an opening read, so a replaced log must arrive from its start.
test("a log that shrank is read again from its start", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const from = tc.draw(gs.integers({ minValue: bytes.length + 1 }));
    const finished = tc.draw(gs.booleans());
    assert.deepEqual(
      await jobLog(logPath, from, finished, options),
      await jobLog(logPath, 0, finished, options),
    );
  }, FILES));

test("following a finished log reconstructs the rest of it exactly", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const reads = await follow(bytes, true, options);
    assert.equal(reads.at(-1).next, bytes.length);
    assert.equal(
      reads.map((read) => read.text).join(""),
      decoded(bytes.subarray(reads[0].from)),
    );
  }, FILES));

test("following a running log stops only where no line or chunk is complete", () =>
  hegel.testAsync(async (tc) => {
    const bytes = drawLog(tc);
    const options = drawKnobs(tc, bytes.length);
    const reads = await follow(bytes, false, options);
    const rest = bytes.subarray(reads.at(-1).next);
    assert.ok(!rest.includes(0x0a) && rest.length < options.chunk);
    assert.equal(
      reads.map((read) => read.text).join(""),
      decoded(bytes.subarray(reads[0].from, reads.at(-1).next)),
    );
  }, FILES));

// The page's view of a log that grows between polls, as readLog keeps it:
// whatever was written and polled shows exactly once, in order, and a log
// replaced by a shorter one starts the view over.
test("a reader polling a growing log sees what was written, whole", () =>
  hegel.testAsync(
    async (tc) => {
      const options = drawKnobs(
        tc,
        tc.draw(gs.integers({ minValue: 0, maxValue: 64 })),
      );
      const world = {
        written: Buffer.alloc(0),
        finished: false,
        replaced: false,
        cursor: null,
        start: 0,
        shown: "",
      };
      writeFileSync(logPath, world.written);
      await hegel.stateful.runAsync(
        tc,
        {
          rules: {
            write: (tc, world) => {
              // A replacement that grows past the reader before it polls
              // cannot be told from growth.
              tc.assume(!world.finished && !world.replaced);
              world.written = Buffer.concat([world.written, tc.draw(logBytes)]);
              writeFileSync(logPath, world.written);
            },
            replace: (tc, world) => {
              tc.assume(!world.finished && world.cursor > 0);
              const bytes = tc.draw(logBytes);
              const size = tc.draw(
                gs.integers({
                  minValue: 0,
                  maxValue: Math.min(bytes.length, world.cursor - 1),
                }),
              );
              world.written = bytes.subarray(0, size);
              world.replaced = true;
              writeFileSync(logPath, world.written);
            },
            finish: (tc, world) => {
              tc.assume(!world.finished);
              world.finished = true;
            },
            poll: async (_tc, world) => {
              const read = await jobLog(
                logPath,
                world.cursor,
                world.finished,
                options,
              );
              if (world.cursor === null || read.from < world.cursor) {
                world.start = read.from;
                world.shown = "";
              } else {
                assert.equal(read.from, world.cursor);
              }
              world.cursor = read.next;
              world.shown += read.text;
              world.replaced = false;
            },
          },
          invariants: {
            shownIsWhatWasWritten: (_tc, world) => {
              // Until it polls, the reader still shows the log it last read.
              if (world.cursor === null || world.replaced) return;
              assert.equal(
                world.shown,
                decoded(world.written.subarray(world.start, world.cursor)),
              );
            },
          },
        },
        world,
      );
    },
    { testCases: 500 },
  ));

// --- cachedFeed ----------------------------------------------------------------

// Drives a feed whose collection settles only when the test says so, against
// a model of its cache.
test("a cached feed answers as a model of its cache predicts", () =>
  hegel.testAsync(
    async (tc) => {
      const maxAge = tc.draw(gs.integers({ minValue: 0, maxValue: 100_000 }));
      const world = {
        clock: tc.draw(gs.integers({ minValue: 0, maxValue: 2 ** 40 })),
        collections: 0,
        settle: null,
        cache: null,
        failure: null,
      };
      // What the next collection does: resolve, reject with any value, or
      // throw before returning a promise.
      world.next = null;
      const feed = cachedFeed(
        () => {
          world.collections += 1;
          if (world.next.kind === "throw") throw world.next.reason;
          return new Promise((resolve, reject) => {
            world.settle = { resolve, reject };
          });
        },
        maxAge,
        () => world.clock,
      );
      const outcome = gs.oneOf(
        gs.record({ kind: gs.just("resolve"), value: gs.integers() }),
        gs.record({
          kind: gs.sampledFrom(["reject", "throw"]),
          reason: gs.oneOf(
            gs.text().map((message) => new Error(message)),
            gs.text(),
            gs.just(null),
            gs.just(undefined),
          ),
        }),
      );
      const messageOf = (reason) =>
        reason instanceof Error ? reason.message : String(reason);
      const recent = (at) => world.clock - at < maxAge;
      const cached = (stale, error) => ({
        value: {
          snapshot: world.cache.data,
          fetchedAt: world.cache.fetchedAt,
          stale,
          error,
        },
      });
      await hegel.stateful.runAsync(
        tc,
        {
          rules: {
            // Wall clocks step backwards too.
            tick: (tc, world) => {
              world.clock += tc.draw(
                gs.integers({
                  minValue: -maxAge - 1,
                  maxValue: 2 * maxAge + 1,
                }),
              );
            },
            request: async (tc, world) => {
              const callers = tc.draw(
                gs.integers({ minValue: 1, maxValue: 4 }),
              );
              world.next = tc.draw(outcome);
              const delay = tc.draw(
                gs.integers({ minValue: 0, maxValue: 2 * maxAge + 1 }),
              );
              const fresh =
                world.cache !== null && recent(world.cache.fetchedAt);
              const failing =
                world.failure !== null && recent(world.failure.at);
              const before = world.collections;
              const answers = Array.from({ length: callers }, () =>
                feed().then(
                  (value) => ({ value }),
                  (error) => ({ error: error.message }),
                ),
              );
              let expected;
              if (fresh || failing) {
                assert.equal(
                  world.collections,
                  before,
                  "no collection within maxAge of the last",
                );
                if (fresh) expected = cached(false, null);
                else if (world.cache)
                  expected = cached(true, world.failure.message);
                else expected = { error: world.failure.message };
              } else {
                assert.equal(
                  world.collections,
                  before + 1,
                  "callers share one collection",
                );
                world.clock += delay;
                if (world.next.kind === "resolve")
                  world.settle.resolve(world.next.value);
                else if (world.next.kind === "reject")
                  world.settle.reject(world.next.reason);
                if (world.next.kind === "resolve") {
                  world.cache = {
                    data: world.next.value,
                    fetchedAt: world.clock,
                  };
                  world.failure = null;
                  expected = cached(false, null);
                } else {
                  world.failure = {
                    message: messageOf(world.next.reason),
                    at: world.clock,
                  };
                  expected = world.cache
                    ? cached(true, world.failure.message)
                    : { error: world.failure.message };
                }
              }
              for (const answer of await Promise.all(answers))
                assert.deepEqual(answer, expected);
            },
          },
        },
        world,
      );
    },
    { testCases: 1000 },
  ));

// --- actionsRun ----------------------------------------------------------------

const STATUSES = [
  "queued",
  "in_progress",
  "completed",
  "waiting",
  "requested",
  "pending",
];
const CONCLUSIONS = [
  "success",
  "failure",
  "neutral",
  "cancelled",
  "skipped",
  "timed_out",
  "action_required",
  "stale",
  "startup_failure",
];
const maybe = (generator) =>
  gs.oneOf(gs.just(undefined), gs.just(null), generator);

const githubRun = gs.record({
  id: maybe(gs.integers({ minValue: 0 })),
  name: maybe(
    gs.oneOf(gs.sampledFrom(["build", "check", "deploy"]), gs.text()),
  ),
  display_title: maybe(gs.text()),
  status: maybe(gs.oneOf(gs.sampledFrom(STATUSES), gs.text())),
  conclusion: maybe(gs.oneOf(gs.sampledFrom(CONCLUSIONS), gs.text())),
  created_at: maybe(gs.datetimes()),
  head_branch: maybe(gs.oneOf(gs.sampledFrom(["main", "topic"]), gs.text())),
  head_sha: maybe(gs.fromRegex("[0-9a-f]{40}", { fullmatch: true })),
  path: maybe(
    gs.oneOf(
      gs.sampledFrom([".github/workflows/ci.yml", "dynamic/copilot"]),
      gs.text(),
    ),
  ),
  html_url: maybe(gs.urls()),
  run_number: maybe(gs.integers({ minValue: 0 })),
  run_attempt: maybe(gs.integers({ minValue: 0 })),
  event: maybe(gs.sampledFrom(["push", "pull_request", "schedule"])),
});

test("a run's state follows GitHub's status and conclusion", () =>
  hegel.test((tc) => {
    const run = tc.draw(githubRun);
    let expected = "failed";
    if (run.status !== "completed") expected = "running";
    else if (run.conclusion === "success") expected = "passed";
    else if (["cancelled", "skipped", "neutral"].includes(run.conclusion))
      expected = "skipped";
    assert.equal(actionsRun(run, new Set()).state, expected);
  }, MANY));

test("a run is retired exactly when its workflow file is not active", () =>
  hegel.test((tc) => {
    const run = tc.draw(githubRun);
    const active = new Set(
      tc.draw(gs.arrays(gs.oneOf(gs.just(run.path ?? ""), gs.text()))),
    );
    assert.equal(actionsRun(run, active).retired, !active.has(run.path || ""));
  }, MANY));

test("a run's fields carry over, with defaults for missing ones", () =>
  hegel.test((tc) => {
    const run = tc.draw(githubRun);
    const reduced = actionsRun(run, new Set());
    assert.deepEqual(
      {
        id: reduced.id,
        workflow: reduced.workflow,
        title: reduced.title,
        conclusion: reduced.conclusion,
        created: reduced.created,
        branch: reduced.branch,
        sha: reduced.sha,
        path: reduced.path,
        url: reduced.url,
        number: reduced.number,
        attempt: reduced.attempt,
        event: reduced.event,
      },
      {
        id: run.id || 0,
        workflow: run.name || "workflow",
        title: run.display_title || "",
        conclusion: run.conclusion ?? null,
        created: run.created_at || null,
        branch: run.head_branch || "",
        sha: run.head_sha || "",
        path: run.path || "",
        url: run.html_url || "",
        number: run.run_number || 0,
        attempt: run.run_attempt || 1,
        event: run.event || "",
      },
    );
  }, MANY));

// --- summarizeActions ----------------------------------------------------------

// Runs as actionsRun leaves them, newest first, from a few workflows and
// branches so that they collide.
const name = (common) =>
  gs.oneOf(gs.sampledFrom(common), gs.text({ maxSize: 4 }));
const reducedRun = gs.composite((tc) => ({
  id: tc.draw(gs.integers({ minValue: 1 })),
  workflow: tc.draw(name(["build", "check", "deploy"])),
  branch: tc.draw(name(["main", "main", "topic", "fix"])),
  state: tc.draw(gs.sampledFrom(["failed", "running", "passed", "skipped"])),
  retired: tc.draw(gs.booleans()),
}));
const reducedRuns = gs.arrays(reducedRun);

function drawAlive(tc, runs) {
  return tc.draw(
    gs.optional(
      gs.arrays(
        gs.oneOf(
          gs.sampledFrom(runs.map((run) => run.branch).concat("main")),
          gs.text(),
        ),
      ),
    ),
  );
}

// Each workflow's counted main runs, newest first.
function mainHistory(runs) {
  const history = new Map();
  for (const run of runs) {
    if (run.branch !== "main" || run.state === "skipped") continue;
    history.set(run.workflow, [...(history.get(run.workflow) ?? []), run]);
  }
  return history;
}

test("main has one verdict per workflow, from its newest counted run there", () =>
  hegel.test((tc) => {
    const runs = tc.draw(reducedRuns);
    const { main } = summarizeActions(runs, null);
    const history = mainHistory(runs);
    assert.deepEqual(
      new Map(main.map((verdict) => [verdict.workflow, verdict.run])),
      new Map(
        [...history].map(([workflow, mainRuns]) => [workflow, mainRuns[0]]),
      ),
    );
    assert.equal(main.length, history.size);
  }, MANY));

test("a verdict's state is its newest run's, or retired", () =>
  hegel.test((tc) => {
    for (const verdict of summarizeActions(tc.draw(reducedRuns), null).main) {
      assert.equal(
        verdict.state,
        verdict.run.retired ? "retired" : verdict.run.state,
      );
    }
  }, MANY));

test("a streak counts main's failures since it last passed or ran", () =>
  hegel.test((tc) => {
    const runs = tc.draw(reducedRuns);
    const history = mainHistory(runs);
    for (const verdict of summarizeActions(runs, null).main) {
      const mainRuns = history.get(verdict.workflow);
      const ended = mainRuns.findIndex((run) => run.state !== "failed");
      const streak = ended === -1 ? mainRuns.length : ended;
      assert.equal(verdict.streak, streak);
      assert.equal(verdict.streakOpen, ended === -1);
    }
  }, MANY));

test("failing verdicts come first, then running, passing, and retired", () =>
  hegel.test((tc) => {
    const rank = { failed: 0, running: 1, passed: 2, retired: 3 };
    const ranks = summarizeActions(tc.draw(reducedRuns), null).main.map(
      (verdict) => rank[verdict.state],
    );
    assert.deepEqual(
      ranks,
      [...ranks].sort((a, b) => a - b),
    );
  }, MANY));

test("branches show each live branch's newest run when it fails or runs", () =>
  hegel.test((tc) => {
    const runs = tc.draw(reducedRuns);
    const alive = drawAlive(tc, runs);
    const newest = [];
    for (const run of runs) {
      if (run.branch === "main" || run.state === "skipped") continue;
      const seen = newest.some(
        (other) =>
          other.workflow === run.workflow && other.branch === run.branch,
      );
      if (!seen) newest.push(run);
    }
    const expected = newest.filter(
      (run) =>
        ["failed", "running"].includes(run.state) &&
        !run.retired &&
        (alive === null || alive.includes(run.branch)),
    );
    const { branches } = summarizeActions(
      runs,
      alive === null ? null : new Set(alive),
    );
    assert.deepEqual(new Set(branches), new Set(expected));
    assert.equal(branches.length, expected.length);
  }, MANY));

test("skipped runs change nothing", () =>
  hegel.test((tc) => {
    const runs = tc.draw(reducedRuns);
    const skipped = tc.draw(
      gs.arrays(reducedRun.map((run) => ({ ...run, state: "skipped" }))),
    );
    const mixed = [...runs];
    for (const run of skipped) {
      mixed.splice(
        tc.draw(gs.integers({ minValue: 0, maxValue: mixed.length })),
        0,
        run,
      );
    }
    assert.deepEqual(
      summarizeActions(mixed, null),
      summarizeActions(runs, null),
    );
  }, MANY));

test("no list of live branches keeps every branch", () =>
  hegel.test((tc) => {
    const runs = tc.draw(reducedRuns);
    assert.deepEqual(
      summarizeActions(runs, null),
      summarizeActions(runs, new Set(runs.map((run) => run.branch))),
    );
  }, MANY));

// --- summarizeJobs -------------------------------------------------------------

const QUIET = ["success", "skipped", "neutral", "cancelled"];
const FAILING = ["failure", "timed_out", "startup_failure"];
const githubJob = gs.record({
  name: maybe(gs.text()),
  conclusion: maybe(
    gs.oneOf(
      gs.sampledFrom([...QUIET, ...FAILING, "action_required", "stale"]),
      gs.text(),
    ),
  ),
  started_at: maybe(gs.datetimes()),
  completed_at: maybe(gs.datetimes()),
  html_url: maybe(gs.urls()),
  steps: maybe(
    gs.arrays(
      gs.record({
        name: gs.text(),
        conclusion: maybe(gs.sampledFrom(["success", "failure", "skipped"])),
      }),
    ),
  ),
});

test("every job is either counted as quiet or listed", () =>
  hegel.test((tc) => {
    const jobs = tc.draw(gs.arrays(githubJob));
    const { jobs: listed, quiet } = summarizeJobs({ jobs });
    for (const conclusion of QUIET) {
      assert.equal(
        quiet[conclusion] ?? 0,
        jobs.filter((job) => job.conclusion === conclusion).length,
      );
    }
    assert.deepEqual(
      Object.keys(quiet).filter((key) => !QUIET.includes(key)),
      [],
    );
    assert.equal(
      listed.length,
      jobs.filter((job) => !QUIET.includes(job.conclusion)).length,
    );
  }, MANY));

test("failed jobs come first, otherwise in GitHub's order", () =>
  hegel.test((tc) => {
    const jobs = tc.draw(gs.arrays(githubJob));
    const named = jobs.map((job, index) => ({
      ...job,
      html_url: `job-${index}`,
    }));
    const loud = named.filter((job) => !QUIET.includes(job.conclusion ?? null));
    const expected = [
      ...loud.filter((job) => FAILING.includes(job.conclusion)),
      ...loud.filter((job) => !FAILING.includes(job.conclusion)),
    ].map((job) => job.html_url);
    assert.deepEqual(
      summarizeJobs({ jobs: named }).jobs.map((job) => job.url),
      expected,
    );
  }, MANY));

test("a listed job names its failed steps in order", () =>
  hegel.test((tc) => {
    const job = { ...tc.draw(githubJob), conclusion: "failure" };
    const [listed] = summarizeJobs({ jobs: [job] }).jobs;
    assert.deepEqual(
      listed.failedSteps,
      asArray(job.steps)
        .filter((step) => step.conclusion === "failure")
        .map((step) => step.name),
    );
  }, MANY));

test("a jobs response without a jobs array lists no jobs", () =>
  hegel.test((tc) => {
    const data = tc.draw(
      gs.oneOf(
        gs.just(null),
        gs.just(undefined),
        gs.just({}),
        gs.record({
          jobs: gs.oneOf(gs.integers(), gs.text(), gs.just(null), gs.just({})),
        }),
      ),
    );
    assert.deepEqual(summarizeJobs(data), { jobs: [], quiet: {} });
  }, MANY));

// --- workflowHeader ------------------------------------------------------------

// Words hold no whitespace (in String.prototype.trim's sense) and no period.
const word = gs.text({
  minSize: 1,
  maxSize: 8,
  excludeCategories: ["Zs", "Zl", "Zp"],
  excludeCharacters: " .\t\n\v\f\r\ufeff",
});
const sentence = gs
  .arrays(word, { minSize: 1, maxSize: 6 })
  .map((words) => words.join(" "));

test("a workflow's description is its header comment's first sentence", () =>
  hegel.test((tc) => {
    const sentences = tc.draw(gs.arrays(sentence, { minSize: 1, maxSize: 4 }));
    const words = sentences
      .map((text) => `${text}.`)
      .join(" ")
      .split(" ");
    // Wrap the header at arbitrary words, with any number of hashes.
    const lines = [];
    for (const piece of words) {
      if (lines.length === 0 || tc.draw(gs.booleans())) lines.push([]);
      lines.at(-1).push(piece);
    }
    const header = lines.flatMap((line) => [
      `${"#".repeat(tc.draw(gs.integers({ minValue: 1, maxValue: 3 })))} ${line.join(" ")}`,
      ...(tc.draw(gs.booleans()) ? ["#"] : []),
    ]);
    const before = tc.draw(gs.sampledFrom([[], [""], ["---"], ["name: CI"]]));
    const bom = tc.draw(gs.sampledFrom(["", "﻿"]));
    const file =
      bom +
      [
        ...before,
        ...header,
        "on: push",
        "jobs:",
        "  # build: not the header.",
      ].join("\n");
    assert.equal(workflowHeader(file), sentences[0]);
  }, MANY));

test("a workflow's description is one line and at most one sentence", () =>
  hegel.test((tc) => {
    const description = workflowHeader(tc.draw(gs.text()));
    assert.ok(!description.includes("\n") && !description.includes(". "));
  }, MANY));

test("a workflow without a header comment has no description", () =>
  hegel.test((tc) => {
    const body = tc.draw(
      gs.arrays(gs.text().map((line) => line.replace(/^#*/, "x"))),
    );
    const after = tc.draw(gs.arrays(gs.text()));
    assert.equal(workflowHeader([...body, "jobs:", ...after].join("\n")), "");
  }, MANY));

// --- excerpt and failedLogs ----------------------------------------------------

// Lines of a failed job's log, tagged with what they are. Plain lines start
// with "> " so that no noise pattern matches them.
const NOISE = [
  "copying path '/nix/store/abc-foo' from 'https://cache.nixos.org'...",
  "downloading 'https://example.org/source.tar.gz'...",
  "these 3 paths will be fetched (1.2 MiB download, 5.0 MiB unpacked):",
  "this path will be built:",
  "  /nix/store/0123456789abcdfghijklmnpqrsvwxyz-foo",
];
const logLine = gs.oneOf(
  gs.record({ kind: gs.just("noise"), text: gs.sampledFrom(NOISE) }),
  gs.record({
    kind: gs.just("plain"),
    text: gs.text().map((text) => `> ${text}`),
  }),
  gs.record({
    kind: gs.just("error"),
    text: gs.text().map((text) => `> ##[error]${text}`),
  }),
);

test("an excerpt is the last lines before and through the last error, without noise", () =>
  hegel.test((tc) => {
    const lines = tc.draw(gs.arrays(logLine));
    const tail = tc.draw(gs.integers({ minValue: 0, maxValue: 40 }));
    const kept = lines.filter((line) => line.kind !== "noise");
    const lastError = kept.findLastIndex((line) => line.kind === "error");
    const end = lastError === -1 ? kept.length : lastError + 1;
    assert.deepEqual(
      excerpt(
        lines.map((line) => line.text),
        tail,
      ),
      kept.slice(Math.max(0, end - tail), end).map((line) => line.text),
    );
  }, MANY));

test("an excerpt of any lines keeps their order, at most tail long", () =>
  hegel.test((tc) => {
    const lines = tc.draw(
      gs.arrays(gs.oneOf(gs.text(), gs.sampledFrom(NOISE))),
    );
    const tail = tc.draw(gs.integers({ minValue: 0, maxValue: 40 }));
    const result = excerpt(lines, tail);
    assert.ok(result.length <= tail);
    let position = 0;
    for (const line of result) {
      position = lines.indexOf(line, position) + 1;
      assert.ok(
        position > 0,
        `${JSON.stringify(line)} is out of order or not in the input`,
      );
    }
  }, MANY));

test("an excerpt keeps LOG_TAIL lines by default", () =>
  hegel.test((tc) => {
    const lines = tc.draw(gs.arrays(gs.text().map((text) => `> ${text}`)));
    assert.deepEqual(excerpt(lines), lines.slice(-LOG_TAIL));
  }, MANY));

// `gh run view --log-failed`: job, step, and a timestamped message per line.
const jobOrStep = (common) =>
  gs.oneOf(
    gs.sampledFrom(common),
    gs.text({ maxSize: 6, excludeCharacters: "\t\n" }),
  );
const failedLine = gs.record({
  job: jobOrStep(["build", "check"]),
  step: jobOrStep(["Run nix flake check", "Set up job"]),
  stamp: gs
    .datetimes()
    .map((stamp) => `${stamp.replace(/[+-]\d\d:\d\d$|Z$/, "")}.1234567Z `),
  message: gs.oneOf(
    logText.map((text) => text.replaceAll("\n", "")),
    gs.sampledFrom([
      "##[error]Process completed with exit code 1.",
      "\x1b[31merror:\x1b[0m builder failed",
    ]),
  ),
});
const failedLog = gs.arrays(failedLine).map((lines) => ({
  lines,
  text: lines
    .map(
      ({ job, step, stamp, message }) => `${job}\t${step}\t${stamp}${message}`,
    )
    .join("\n"),
}));

test("failed logs group lines by job and step, in order of first appearance", () =>
  hegel.test((tc) => {
    const { lines, text } = tc.draw(failedLog);
    const pairs = [];
    for (const { job, step } of lines) {
      if (!pairs.some((pair) => pair.job === job && pair.step === step))
        pairs.push({ job, step });
    }
    assert.deepEqual(
      failedLogs(text).map(({ job, step }) => ({ job, step })),
      pairs,
    );
  }, MANY));

// Any text at all, lines without tabs or timestamps included: each non-empty
// line's first two fields name exactly one group.
test("failed logs group any text by its lines' first two fields", () =>
  hegel.test((tc) => {
    const text = tc.draw(gs.oneOf(gs.text(), logText));
    const pairs = new Set(
      text
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [job = "", step = ""] = line.split("\t");
          return JSON.stringify([job, step]);
        }),
    );
    const groups = failedLogs(text).map(({ job, step }) =>
      JSON.stringify([job, step]),
    );
    assert.deepEqual(new Set(groups), pairs);
    assert.equal(groups.length, pairs.size);
  }, MANY));

test("a failed step's lines are its messages' excerpt, without timestamps or colors", () =>
  hegel.test((tc) => {
    const { lines, text } = tc.draw(failedLog);
    for (const group of failedLogs(text)) {
      const messages = lines
        .filter(({ job, step }) => job === group.job && step === group.step)
        .map(({ message }) => message.replace(SGR, ""));
      assert.deepEqual(group.lines, excerpt(messages));
    }
  }, MANY));

// --- asArray -------------------------------------------------------------------

test("asArray keeps arrays and reads anything else as empty", () =>
  hegel.test((tc) => {
    const value = tc.draw(
      gs.oneOf(
        gs.arrays(gs.integers()),
        gs.integers(),
        gs.text(),
        gs.just(null),
        gs.just(undefined),
        gs.just({ length: 1 }),
      ),
    );
    if (Array.isArray(value)) assert.equal(asArray(value), value);
    else assert.deepEqual(asArray(value), []);
  }, MANY));

// --- scale ---------------------------------------------------------------------

// Once, at production sizes: a 24 MiB log followed with the default window and
// chunk, and Actions and log reductions over hundreds of thousands of items.
test("the reductions stay whole and linear at scale", async () => {
  const line = Buffer.from(
    "\x1b[32mbuilding\x1b[0m '/nix/store/abc-é日本🦀.drv'...\n",
  );
  const bytes = Buffer.concat(
    Array.from({ length: (24 << 20) / line.length }, () => line),
  );
  writeFileSync(logPath, bytes);
  const started = performance.now();
  const reads = await follow(bytes, true, {
    window: JOB_LOG_WINDOW,
    chunk: JOB_LOG_CHUNK,
  });
  assert.equal(reads.at(-1).next, bytes.length);
  assert.ok(reads[0].clipped);
  assert.equal(
    reads.map((read) => read.text).join(""),
    decoded(bytes.subarray(reads[0].from)),
  );

  const runs = Array.from({ length: 300_000 }, (_, index) => ({
    id: index + 1,
    workflow: `workflow-${index % 50}`,
    branch: index % 3 ? `branch-${index % 997}` : "main",
    state: ["failed", "running", "passed", "skipped"][index % 4],
    retired: index % 7 === 0,
  }));
  assert.ok(summarizeActions(runs, null).main.length <= 50);

  const log = Array.from(
    { length: 300_000 },
    (_, index) =>
      `job-${index % 40}\tstep-${index % 9}\t2026-10-16T00:00:00.0000000Z line ${index}`,
  ).join("\n");
  assert.equal(failedLogs(log).length, 360);
  assert.ok(performance.now() - started < 20_000, "scale probe took over 20 s");
});
