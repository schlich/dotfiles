// A changing CI world for the dashboard's Bombadil check: fake `ci` and `gh`
// commands read it from $CI_FAKE_STATE, take a random step, and answer as the
// real ones would. Runs are never removed, so every log the page saw stays
// readable.
import {
  appendFileSync,
  existsSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

export const dir = process.env.CI_FAKE_STATE ?? ".";
export const seed = Number(process.env.CI_FAKE_SEED ?? Date.now()) | 0;
export const REPO = "/home/u/repo";
export const ROOTS = [
  REPO,
  ...["feat-login", "fix-cache", "merge-fix", "docs"].map(
    (name) => `${REPO}/.jj-workspaces/${name}`,
  ),
];
const MINUTE = 60_000;

// mulberry32, so that a run of the check can be replayed from its seed.
export function random(world) {
  world.rng = (world.rng + 0x6d2b79f5) | 0;
  let t = world.rng;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
export const pick = (world, items) =>
  items[Math.floor(random(world) * items.length)];
export const chance = (world, p) => random(world) < p;

// Build-log text: Nix noise, colored errors, passes, multi-byte characters,
// long lines, and sometimes a line still being written.
export function logText(world, lines) {
  const kinds = [
    () =>
      `building '/nix/store/${"0123456789abcdfg".repeat(2)}-dotfiles-${Math.floor(random(world) * 99)}.drv'...`,
    () =>
      "copying path '/nix/store/abc-source' from 'https://cache.nixos.org'...",
    () =>
      "\x1b[31;1merror:\x1b[0m builder for '/nix/store/xyz-check.drv' failed with exit code 1",
    () => "##[error]Process completed with exit code 1.",
    () => "\x1b[32m✓\x1b[0m checks passed",
    () => "évaluation 日本語 🦀 done",
    () => `progress ${"█".repeat(Math.floor(random(world) * 400))}`,
    () => "x".repeat(Math.floor(random(world) * 3000)),
    () => "",
  ];
  let text = "";
  for (let index = 0; index < lines; index += 1)
    text += `${pick(world, kinds)()}\n`;
  if (chance(world, 0.4)) text += "still writing é";
  return text;
}

function makeRun(world, now, overrides) {
  world.runCount += 1;
  const id = `r${world.runCount}`;
  const log = join(dir, `${id}.log`);
  writeFileSync(log, logText(world, 3 + Math.floor(random(world) * 30)));
  return {
    id,
    source: pick(world, ["store", "shell"]),
    args: pick(world, [
      ["preflight"],
      ["dispatch", "--land"],
      ["land"],
      ["verify"],
      ["new", "-m", "Fix it"],
    ]),
    workspace: chance(world, 0.15) ? "/home/u/other-repo" : pick(world, ROOTS),
    log,
    status_file: "",
    started_ms: now - Math.floor(random(world) * 30 * MINUTE),
    ended_ms: null,
    state: "running",
    exit_code: null,
    phases: [
      {
        id: "build",
        state: "working",
        msg: "building hosts",
        started_ms: now,
        ended_ms: null,
      },
    ],
    summary: null,
    mutating: chance(world, 0.5),
    pid: 4000 + world.runCount,
    ...overrides,
  };
}

function finish(
  world,
  run,
  now,
  state = pick(world, ["succeeded", "failed", "lost"]),
) {
  run.state = state;
  run.exit_code =
    run.state === "succeeded"
      ? 0
      : run.state === "failed"
        ? pick(world, [1, 2])
        : null;
  run.ended_ms = now;
  run.pid = null;
  const phase = run.phases.at(-1);
  if (phase) {
    phase.state =
      run.state === "failed"
        ? "error"
        : run.state === "succeeded"
          ? "done"
          : "working";
    if (run.state !== "lost") phase.ended_ms = now;
  }
  run.summary =
    run.state === "lost"
      ? null
      : [
          run.state === "failed" ? "error" : "done",
          `${run.args[0]} ${run.state}`,
        ];
  if (run.state !== "lost")
    appendFileSync(
      run.log,
      run.state === "failed" ? "\x1b[31merror:\x1b[0m failed\n" : "done\n",
    );
}

const TOPIC_STAGES = [
  "editing",
  "validated",
  "published",
  "passed",
  "failed",
  "republish",
  "landed",
  "stranded",
  "idle",
  "finished",
];

function makeTopic(world, key, now) {
  return {
    key,
    workspace: key,
    root: `${REPO}/.jj-workspaces/${key}`,
    current: key === "feat-login",
    head: {
      commit_id: `${key}-c`,
      change_id: `${key}-id`,
      short: key.slice(0, 8),
      title: pick(world, [
        "Add login form",
        "Fix cache",
        "",
        "escape <b>&amp;</b>",
      ]),
      described: true,
      empty: false,
      conflict: false,
      divergent: false,
      impact: [],
      time_ms: now,
    },
    stack: [],
    idle: false,
    behind: pick(world, [0, 2, 5, null]),
    branch: key,
    published_head: null,
    landed: false,
    owner: pick(world, ["codex", "claude", "u", ""]),
    lint: { state: "never" },
    ci: null,
    stranded: null,
    reviews: [],
    stage: pick(world, TOPIC_STAGES),
    next: "Next step",
    allowed: [],
    conflicts: [],
  };
}

export function createLocal() {
  const now = Date.now();
  const world = {
    rng: seed,
    tick: 0,
    runCount: 0,
    runs: [],
    topics: [],
    trunk: [],
    checksLock: false,
  };
  // Finished runs from the last 26 hours, some outside the page's 24-hour
  // window, then two still running.
  for (const state of [
    "failed",
    "succeeded",
    "lost",
    "succeeded",
    "failed",
    "running",
    "running",
  ]) {
    const started = now - Math.floor(random(world) * 26 * 60 * MINUTE);
    const run = makeRun(
      world,
      now,
      state === "running" ? {} : { started_ms: started },
    );
    if (state !== "running")
      finish(
        world,
        run,
        started + Math.floor(random(world) * 10 * MINUTE),
        state,
      );
    world.runs.push(run);
  }
  world.topics = [
    "feat-login",
    "fix-cache",
    "merge-fix",
    "docs",
    "release-notes",
  ].map((key) => makeTopic(world, key, now));
  for (let index = 0; index < 7; index += 1) {
    world.trunk.push({
      commit_id: `t${index}`,
      short: `t${index}abcdef`.slice(0, 8),
      title: `trunk change ${index}`,
      impact: pick(world, [[], ["behavior"], ["refactor"]]),
      tags: [],
      author: "u",
      time_ms: now - index * 5 * 60 * MINUTE,
    });
  }
  return world;
}

// `ci` and `gh` keep separate files, since the server runs them at once, and
// replace them whole, since a read-only `gh` call may read during a write.
export function load(name, create) {
  const path = join(dir, name);
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : create();
}

export function save(name, world) {
  const path = join(dir, name);
  writeFileSync(`${path}.tmp`, JSON.stringify(world));
  renameSync(`${path}.tmp`, path);
}

// One step of the local world: logs grow or are replaced, runs start and end,
// topics move, and changes land.
export function step(world) {
  const now = Date.now();
  world.tick += 1;
  const running = () => world.runs.filter((run) => run.state === "running");
  for (let count = 1 + Math.floor(random(world) * 3); count > 0; count -= 1) {
    const event = pick(world, [
      "grow",
      "grow",
      "grow",
      "finish",
      "start",
      "replace",
      "topic",
      "land",
      "lock",
    ]);
    const run = running().length ? pick(world, running()) : null;
    if (event === "grow" && run)
      appendFileSync(run.log, logText(world, Math.floor(random(world) * 40)));
    if (event === "replace" && run)
      writeFileSync(run.log, logText(world, Math.floor(random(world) * 4)));
    if (event === "finish" && run) finish(world, run, now);
    if (event === "start")
      world.runs.push(makeRun(world, now, { started_ms: now }));
    if (event === "topic") {
      const topic = pick(world, world.topics);
      topic.stage = pick(world, TOPIC_STAGES);
      topic.landed = topic.stage === "landed";
      topic.head.conflict = chance(world, 0.2);
      topic.conflicts = topic.head.conflict ? ["modules/cache.nix"] : [];
      topic.behind = pick(world, [0, 1, 3, null]);
    }
    if (event === "land") {
      world.trunk.unshift({
        commit_id: `t${world.tick}x`,
        short: `${world.tick}landed`.slice(0, 8),
        title: `landed at tick ${world.tick}`,
        impact: ["behavior"],
        tags: [],
        author: "u",
        time_ms: now,
      });
    }
    if (event === "lock") world.checksLock = !world.checksLock;
  }
}

export function tower(world) {
  const now = Date.now();
  const holder = (run) => ({
    topic: `${run.id} "${run.args.join(" ")}"`,
    pid: run.pid,
    workspace: run.workspace,
    unit: null,
    since_ms: run.started_ms,
  });
  const runningRun = world.runs.find((run) => run.state === "running");
  return {
    snapshot: {
      repo: REPO,
      trunk: world.trunk,
      topics: world.topics,
      workspace_roots: ROOTS,
      op_heads: null,
      taken_ms: now,
      took_ms: 12,
    },
    runs: [...world.runs].reverse(),
    locks: {
      checks: world.checksLock && runningRun ? holder(runningRun) : null,
      topics: runningRun
        ? [[`${runningRun.id}-change`, holder(runningRun)]]
        : [],
      landing: [],
    },
    host: {
      hostname: "fixture-host",
      verified: { "2026.10.15-a1b2": now - 60 * MINUTE },
      queued: 0,
      activated_ms: now - 30 * MINUTE,
      running: "/nix/store/0000-nixos-system-fixture-host",
    },
  };
}
