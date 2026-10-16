// The `gh api` and `gh run view` calls server.mjs makes, answered from the
// fake world's GitHub Actions runs, which move on with each listing.
import { chance, load, pick, random, save, seed } from "./world.mjs";

const WORKFLOWS = [
  { name: "Flake check", path: ".github/workflows/check.yml", active: true },
  { name: "Docs", path: ".github/workflows/docs.yml", active: true },
  { name: "Lint", path: ".github/workflows/lint.yml", active: true },
  // Removed from main, so its old runs are retired.
  { name: "Nightly", path: ".github/workflows/nightly.yml", active: false },
  {
    name: "Dependabot Updates",
    path: "dynamic/dependabot/dependabot-updates",
    active: true,
  },
];
const LIVE = ["main", "feat-login", "fix-cache"];
const BRANCHES = [...LIVE, "main", "main", "deleted-topic"];

function newRun(world) {
  world.actionCount += 1;
  const workflow = pick(world, WORKFLOWS);
  const status = pick(world, [
    "completed",
    "completed",
    "completed",
    "in_progress",
    "queued",
  ]);
  return {
    id: 9000 + world.actionCount,
    name: workflow.name,
    display_title: pick(world, [
      "Bump inputs",
      "docs: fix typo",
      "WIP login",
      "escape <b>&amp;</b>",
    ]),
    status,
    conclusion:
      status === "completed"
        ? pick(world, [
            "success",
            "success",
            "failure",
            "failure",
            "cancelled",
            "skipped",
            "timed_out",
          ])
        : null,
    created_at: new Date(
      Date.now() - Math.floor(random(world) * 3_600_000),
    ).toISOString(),
    head_branch: pick(world, BRANCHES),
    head_sha: Math.floor(random(world) * 2 ** 52)
      .toString(16)
      .padStart(16, "0"),
    path: workflow.path,
    html_url: `https://github.com/schlich/dotfiles/actions/runs/${9000 + world.actionCount}`,
    run_number: world.actionCount,
    run_attempt: 1,
    event: "push",
  };
}

// A run's jobs depend only on the run, as GitHub's would once it finished.
function jobs(run) {
  const world = { rng: run.id };
  const done = run.status === "completed";
  return Array.from(
    { length: 1 + Math.floor(random(world) * 5) },
    (_, index) => {
      const conclusion = !done
        ? pick(world, [null, "success"])
        : run.conclusion === "failure" && index === 0
          ? "failure"
          : pick(world, [
              "success",
              "skipped",
              "cancelled",
              "neutral",
              run.conclusion,
            ]);
      return {
        name: `build (${["x86_64-linux", "aarch64-linux", "docs", "lint", "checks"][index]})`,
        conclusion,
        started_at: run.created_at,
        completed_at: conclusion
          ? new Date(Date.parse(run.created_at) + 600_000).toISOString()
          : null,
        html_url: `${run.html_url}/job/${index}`,
        steps: [
          { name: "Set up job", conclusion: "success" },
          {
            name: "nix flake check",
            conclusion: conclusion === "failure" ? "failure" : conclusion,
          },
        ],
      };
    },
  );
}

function failedLog(run) {
  const world = { rng: run.id };
  const stamp = run.created_at.replace(/\.\d+Z$|Z$/, ".1234567Z");
  const messages = [
    "copying path '/nix/store/abc-source' from 'https://cache.nixos.org'...",
    "\x1b[31;1merror:\x1b[0m builder for '/nix/store/xyz.drv' failed with exit code 1",
    "##[error]Process completed with exit code 1.",
    "évaluation 日本語 🦀\twith a tab",
    "Post job cleanup.",
  ];
  return jobs(run)
    .filter((job) => job.conclusion === "failure")
    .flatMap((job) =>
      Array.from(
        { length: 3 + Math.floor(random(world) * 25) },
        () => `${job.name}\tnix flake check\t${stamp} ${pick(world, messages)}`,
      ),
    )
    .join("\n");
}

const args = process.argv.slice(2);
const world = load("actions.json", () => ({
  rng: seed ^ 0x9e3779b9,
  actionCount: 0,
  actions: [],
}));
const out = (value) =>
  process.stdout.write(
    typeof value === "string" ? value : JSON.stringify(value),
  );
const path =
  args[0] === "api" ? args.find((arg) => arg.startsWith("repos/")) : null;

// Only the listing moves the world on; the server makes the other calls
// alongside it and after it.
if (path?.includes("/actions/runs?")) {
  for (const run of world.actions) {
    if (run.status !== "completed" && chance(world, 0.5)) {
      run.status = "completed";
      run.conclusion = pick(world, ["success", "failure", "cancelled"]);
    }
  }
  for (
    let count = world.actions.length ? Math.floor(random(world) * 3) : 12;
    count > 0;
    count -= 1
  ) {
    world.actions.unshift(newRun(world));
  }
  world.actions = world.actions.slice(0, 40);
  save("actions.json", world);
  out({ total_count: world.actions.length, workflow_runs: world.actions });
} else if (path?.endsWith("/actions/workflows")) {
  out({
    workflows: WORKFLOWS.map((workflow) => ({
      name: workflow.name,
      path: workflow.path,
      state: workflow.active ? "active" : "disabled_manually",
    })),
  });
} else if (path?.includes("/branches")) {
  out(LIVE.join("\n"));
} else if (path?.includes("/contents/")) {
  const workflow = WORKFLOWS.find((candidate) => path.includes(candidate.path));
  out({
    content: Buffer.from(
      `# ${workflow?.name ?? "A workflow"} checks every host. It runs on push.\nname: x\non: push\njobs:\n`,
    ).toString("base64"),
  });
} else if (path?.includes("/jobs")) {
  const id = Number(path.match(/runs\/(\d+)\/jobs/)?.[1]);
  const run = world.actions.find((candidate) => candidate.id === id);
  out({ total_count: 0, jobs: run ? jobs(run) : [] });
} else if (args[0] === "run" && args[1] === "view") {
  const run = world.actions.find(
    (candidate) => String(candidate.id) === args[2],
  );
  out(run ? failedLog(run) : "");
} else {
  process.stderr.write(`fake gh: no ${args.join(" ")}\n`);
  process.exit(1);
}
