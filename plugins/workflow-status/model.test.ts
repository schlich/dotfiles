import { describe, expect, test } from "bun:test";
import * as M from "./model";

describe("git", () => {
  test("porcelain v2 counts the index and the work tree separately", () => {
    const status = M.parseGitStatus(
      [
        "# branch.oid 08e719c709a5be1d88a0a8d4e91733d391c46970",
        "# branch.head luvus/t40",
        "# branch.upstream origin/luvus/t40",
        "# branch.ab +2 -1",
        "1 .M N... 100644 100644 100644 9a6d 9a6d flake.lock",
        "1 M. N... 100644 100644 100644 aaaa bbbb README.md",
        "1 MM N... 100644 100644 100644 aaaa bbbb tui.tsx",
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 new.ts\told.ts",
        "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.nix",
        "? scratch.txt",
        "",
      ].join("\n"),
    );
    expect(status).toEqual({
      oid: "08e719c709a5be1d88a0a8d4e91733d391c46970",
      branch: "luvus/t40",
      upstream: "origin/luvus/t40",
      ahead: 2,
      behind: 1,
      staged: 3,
      unstaged: 2,
      untracked: 1,
      conflicted: 1,
    });
    expect(M.summarizeVcs({ kind: "git", root: "/r", git: status })).toEqual({
      tone: "error",
      text: "⎇ luvus/t40 ↑2 ↓1 ±7 1 conflicted",
    });
  });

  test("a detached HEAD has no branch", () => {
    const status = M.parseGitStatus(
      "# branch.oid 08e719c7aaaa\n# branch.head (detached)\n",
    );
    expect(status.branch).toBeUndefined();
    expect(M.summarizeVcs({ kind: "git", root: "/r", git: status }).text).toBe(
      "⎇ detached 08e719c7",
    );
  });
});

describe("jj", () => {
  test("the template joins its fields with tabs and ends each commit with a newline", () => {
    expect(M.JJ_TEMPLATE).toContain(
      ' ++ "\\t" ++ change_id.shortest(8) ++ "\\t" ++ ',
    );
    expect(M.JJ_TEMPLATE.endsWith('description.first_line() ++ "\\n"')).toBe(
      true,
    );
  });

  test("an empty working copy on trunk takes trunk's bookmarks", () => {
    // jj 0.46's output for the dotfiles checkout.
    const status = M.parseJjLog(
      "@\t0\tnvkwtotq\td7b80f53\t1\t0\t0\t\t\n" +
        "-\t0\tzlqtxwrq\t08e719c7\t1\t0\t0\tluvus/integration,main\tMerge branch 'nixbot-gates-main' into luvus/integration\n",
    );
    expect(status).toEqual({
      change: {
        changeId: "nvkwtotq",
        commitId: "d7b80f53",
        empty: true,
        conflict: false,
        divergent: false,
        bookmarks: [],
        description: "",
      },
      ahead: 0,
      bookmarks: ["luvus/integration", "main"],
      truncated: false,
    });
    expect(M.summarizeVcs({ kind: "jj", root: "/r", jj: status })).toEqual({
      tone: "ok",
      text: "@ nvkwtotq luvus/integration",
    });
  });

  test("commits ahead of trunk count, and a tab cannot shift the description", () => {
    const status = M.parseJjLog(
      "@\t1\tabc\t111\t0\t1\t0\t\tfix\tthing\n-\t1\tdef\t222\t0\t0\t0\tfeature\tadd feature\n",
    );
    expect(status?.change.description).toBe("fix\tthing");
    expect(status?.change.conflict).toBe(true);
    expect(status?.ahead).toBe(2);
    expect(status?.bookmarks).toEqual(["feature"]);
    expect(M.parseJjLog("-\t0\tdef\t222\t0\t0\t0\t\tparent\n")).toBeUndefined();
  });

  test("a reached limit marks the count as a lower bound", () => {
    const line = "-\t1\tdef\t222\t0\t0\t0\t\tx\n";
    expect(
      M.parseJjLog("@\t1\tabc\t111\t0\t0\t0\t\tx\n" + line.repeat(2), 3)
        ?.truncated,
    ).toBe(true);
  });

  test("the pushed commit is the newest one a real remote has", () => {
    expect(
      M.parseJjPushed(
        "aaaa\tfeature@git\nbbbb\tluvus/integration@git,main@git,main@origin\n",
      ),
    ).toEqual({ commit: "bbbb", refs: ["main@origin"] });
    expect(M.parseJjPushed("aaaa\tfeature@git\n")).toBeUndefined();
  });
});

describe("remotes", () => {
  test("origin's GitHub repository wins", () => {
    const remotes = M.parseRemotes(
      [
        "remote.backup.url git@github.com:someone/fork.git",
        "remote.origin.url https://github.com/schlich/dotfiles.git",
        "remote.forge.url git@git.example.org:schlich/dotfiles",
        "remote.homelab.url homelab:dotfiles",
      ].join("\n"),
    );
    expect(remotes.map((remote) => remote.name)).toEqual([
      "backup",
      "origin",
      "forge",
      "homelab",
    ]);
    expect(M.githubRepository(remotes)).toBe("schlich/dotfiles");
  });

  test("jj git remote list and SSH URLs", () => {
    const remotes = M.parseRemotes(
      "forge git@git.example.org:a/b\nmirror git@github.com:owner/repo.git\n",
    );
    expect(M.githubRepository(remotes)).toBe("owner/repo");
    expect(M.githubSlug("ssh://git@github.com/owner/repo")).toBe("owner/repo");
    expect(
      M.githubSlug("git@git.example.org:schlich/dotfiles"),
    ).toBeUndefined();
  });
});

describe("ci", () => {
  const runs = {
    total_count: 5,
    check_runs: [
      {
        name: "nixbot/nix-eval",
        status: "completed",
        conclusion: "success",
        app: { slug: "nixbot-schlich-dotfiles" },
        html_url: "https://e",
      },
      {
        name: "nixbot/nix-build",
        status: "in_progress",
        conclusion: null,
        app: { slug: "nixbot-schlich-dotfiles" },
      },
      {
        name: "nix flake checks",
        status: "completed",
        conclusion: "failure",
        app: { slug: "github-actions" },
      },
      {
        name: "remote check (ci-dashboard-bombadil, non-blocking)",
        status: "completed",
        conclusion: "failure",
        app: { slug: "github-actions" },
      },
      {
        name: "flake check (${{ matrix.check }})",
        status: "completed",
        conclusion: "skipped",
        app: { slug: "github-actions" },
      },
    ],
  };

  test("check runs keep nixbot's gate apart from what only reports", () => {
    const checks = M.parseCheckRuns(runs);
    expect(
      checks.map((check) => [check.name, check.state, check.gate]),
    ).toEqual([
      ["nixbot/nix-eval", "passed", true],
      ["nixbot/nix-build", "running", true],
      ["nix flake checks", "failed", false],
      ["remote check (ci-dashboard-bombadil, non-blocking)", "warn", false],
      ["flake check (${{ matrix.check }})", "skipped", false],
    ]);
    expect(M.gateState(checks)).toBe("running");
    expect(M.summarizeChecks(checks)).toEqual({
      tone: "error",
      text: "nixbot ● · 1 failed · 1 running · 1 passed",
    });
    expect(M.failingNames(checks)).toBe("nix flake checks");
  });

  test("rows list failures first and link each check", () => {
    const rows = M.ciRows(
      {
        slug: "o/r",
        sha: "0123456789",
        target: "main@origin",
        checks: M.parseCheckRuns(runs),
        pulls: [],
      },
      0,
    );
    expect(rows[0]).toMatchObject({
      label: "main@origin @ 01234567",
      url: "https://github.com/o/r/commit/0123456789",
    });
    expect(rows.slice(1).map((row) => row.tone)).toEqual([
      "error",
      "busy",
      "warn",
      "ok",
      "idle",
    ]);
    expect(rows.find((row) => row.label === "nixbot/nix-eval")?.url).toBe(
      "https://e",
    );
  });

  test("a passing gate with only warnings is a warning", () => {
    const checks = M.parseCheckRuns({
      check_runs: [runs.check_runs[0], runs.check_runs[3]],
    });
    expect(M.summarizeChecks(checks)).toEqual({
      tone: "warn",
      text: "nixbot ✓ · 1 warning · 1 passed",
    });
    expect(M.summarizeChecks([])).toEqual({
      tone: "idle",
      text: "no checks yet",
    });
  });

  test("commit statuses and pull requests", () => {
    const statuses = M.parseStatuses({
      state: "failure",
      statuses: [
        { context: "deploy", state: "pending", target_url: "https://d" },
        { context: "lint", state: "error", description: "boom" },
      ],
    });
    expect(
      statuses.map((check) => [check.name, check.state, check.summary]),
    ).toEqual([
      ["deploy", "running", undefined],
      ["lint", "failed", "boom"],
    ]);
    expect(
      M.parsePulls([
        {
          number: 7,
          title: "Add",
          html_url: "https://p",
          state: "open",
          draft: true,
        },
        { bad: true },
      ]),
    ).toEqual([
      { number: 7, title: "Add", url: "https://p", state: "open", draft: true },
    ]);
  });
});

describe("jobs", () => {
  test("SCRU128 ids carry their mint time", () => {
    // xs reported this frame's timestamp as 2026-11-06T14:59:57.187Z.
    expect(M.scru128Time("03h6r7wqxp1xt3pnos3g5q40s")).toBe(
      Date.parse("2026-11-06T14:59:57.187Z"),
    );
    expect(M.scru128Time("not-an-id")).toBeUndefined();
  });

  test("start and done frames make one job", () => {
    const jobs = new Map<string, M.Job>();
    M.applyFrame(jobs, {
      topic: "job.6314bed8-d6a1-4fea-868f-71c56eca5851.start",
      id: "03h6r7wqxp1xt3pnos3g5q40s",
      meta: {
        log: "/tmp/s/live.log",
        cwd: "/home/u/.luvus/worktrees/dotfiles/__integration",
        pid: 3013758,
      },
    });
    expect(jobs.get("6314bed8-d6a1-4fea-868f-71c56eca5851")).toMatchObject({
      kind: "job",
      label: "live",
      state: "running",
      started: Date.parse("2026-11-06T14:59:57.187Z"),
      pid: 3013758,
    });
    const done = M.applyFrame(jobs, {
      topic: "job.6314bed8-d6a1-4fea-868f-71c56eca5851.done",
      id: "03h6r7z3f0l6l4cwp47kjrd4u",
      meta: { outcome: { exit_code: 1, error: "Can't convert to string." } },
      timestamp: "2026-11-06T15:00:17.209+00:00",
    });
    expect(done).toMatchObject({
      state: "failed",
      exit: 1,
      error: "Can't convert to string.",
      finished: Date.parse("2026-11-06T15:00:17.209Z"),
    });
    expect(
      M.applyFrame(jobs, { topic: "terminal.command.failed", id: "x" }),
    ).toBeUndefined();
  });

  test("ci MCP jobs are named by their command and keep their unit", () => {
    const jobs = new Map<string, M.Job>();
    const job = M.applyFrame(jobs, {
      topic: "job.20261024T151316-park-ce9218.start",
      id: "03h3zc8w6v7x42was2e41u8o2",
      meta: {
        log: "/s/jobs/20261024T151316-park-ce9218/log",
        cwd: "/p/ci",
        pid: 86468,
        unit: "ci-mcp-20261024T151316-park-ce9218",
      },
    });
    expect(job).toMatchObject({
      kind: "ci",
      label: "ci park",
      unit: "ci-mcp-20261024T151316-park-ce9218",
    });
  });

  test("NUON fields may be quoted or bare", () => {
    const record =
      '{pid: 1737056, topic: "job.83396a56", task: "nix run nixpkgs#nix-fast-build -- --flake \\"$ref\\"", cwd: "/home/u", started: 2026-10-27T15:34:24.098243335-05:00}';
    expect(M.nuonField(record, "task")).toBe(
      'nix run nixpkgs#nix-fast-build -- --flake "$ref"',
    );
    expect(
      M.nuonField('{pid: 1, task: luvus-deliver, cwd: "/x"}', "task"),
    ).toBe("luvus-deliver");
    expect(
      M.nuonField(
        '{exit_code: 1, error: "Can\'t convert to string."}',
        "exit_code",
      ),
    ).toBe("1");
    expect(M.nuonField("{exit_code: 0}", "error")).toBeUndefined();
  });

  test("the latest progress report reads as watch-job prints it", () => {
    expect(
      M.latestPhase([
        {
          state: "working",
          id: "switch/build",
          msg: "build 10/20: home-manager-path",
          progress: 60,
        },
        { state: "clear" },
      ]),
    ).toBe("▶ switch/build 60%: build 10/20: home-manager-path");
    expect(
      M.latestPhase([
        { state: "blocked", id: "land", msg: "Waiting for approval" },
      ]),
    ).toBe("⏸ land: Waiting for approval");
    expect(M.latestPhase([])).toBeUndefined();
  });

  test("Claude Code tasks, including another host's report", () => {
    const jobs = M.claudeJobs([
      {
        id: "b4x2",
        description: "nix build",
        cwd: "/src",
        started: "2026-10-07T12:00:00-05:00",
        finished: null,
      },
      {
        host: "laptop",
        updated: "x",
        tasks: [
          {
            id: "c1",
            description: "tests",
            finished: "2026-10-07T12:05:00-05:00",
          },
        ],
      },
      "junk",
    ]);
    expect(jobs.map((job) => [job.id, job.label, job.state])).toEqual([
      ["claude:b4x2", "nix build", "running"],
      ["laptop:claude:c1", "tests (laptop)", "done"],
    ]);
  });

  test("only running and recently finished jobs stay in view", () => {
    const now = Date.parse("2026-11-06T16:00:00Z");
    const jobs: M.Job[] = [
      {
        id: "old",
        kind: "job",
        label: "old",
        state: "done",
        exit: 0,
        finished: now - M.RECENT - 1,
      },
      {
        id: "ok",
        kind: "job",
        label: "ok",
        state: "done",
        exit: 0,
        finished: now - 60_000,
      },
      {
        id: "bad",
        kind: "ci",
        label: "ci land",
        state: "failed",
        exit: 3,
        finished: now - 30_000,
      },
      {
        id: "run",
        kind: "opencode",
        label: "bun test",
        state: "running",
        started: now - 75_000,
        phase: "▶ tests",
        cwd: "/p/app",
      },
    ];
    expect(M.visibleJobs(jobs, now).map((job) => job.id)).toEqual([
      "run",
      "bad",
      "ok",
    ]);
    expect(M.jobRows(jobs, now)[0]?.detail).toBe(
      "shell · ▶ tests · 1m 15s · app",
    );
    expect(M.summarizeJobs(jobs, now)).toEqual({
      tone: "error",
      text: "1 running · 1 failed",
    });
    expect(
      M.shellJob({
        id: "sh_1",
        status: "exited",
        command: "ls",
        cwd: "/",
        exit: 2,
        time: { started: 1, completed: 2 },
      }).state,
    ).toBe("failed");
  });
});

describe("tasks", () => {
  const tasks = M.parseTasks({
    result: {
      tasks: [
        {
          id: "t3",
          status: "merged",
          title: "old",
          branch: "luvus/t3",
          project: { root: "/home/u/dotfiles/.git" },
        },
        {
          id: "t15",
          status: "queued",
          title: "hokum",
          project: { root: "/home/u/dotfiles/.git" },
        },
        {
          id: "t16",
          status: "blocked",
          title: "reverts",
          notes: ["merge conflict"],
          project: { root: "/home/u/dotfiles" },
        },
        {
          id: "t40",
          status: "running",
          title: "workflow status",
          branch: null,
          worktree: null,
          project: { root: "/home/u/dotfiles/.git" },
        },
        {
          id: "t9",
          status: "running",
          title: "elsewhere",
          project: { root: "/home/u/other" },
        },
      ],
    },
  });

  test("a project's tasks match its checkout or its .git", () => {
    expect(
      M.projectTasks(tasks, "/home/u/dotfiles/.git").map((task) => task.id),
    ).toEqual(["t3", "t15", "t16", "t40"]);
  });

  test("a luvus/ID branch names the task even when luvus recorded no branch", () => {
    const mine = M.projectTasks(tasks, "/home/u/dotfiles");
    const current = M.currentTask(mine, {
      root: "/home/u/.luvus/worktrees/dotfiles/luvus-t40",
      branch: "luvus/t40",
    });
    expect(current?.id).toBe("t40");
    const view = { tasks: mine, current };
    expect(M.taskRows(view).map((row) => row.label)).toEqual([
      "◆ t40 workflow status",
      "t16 reverts",
      "t15 hokum",
    ]);
    expect(M.summarizeTasks(view)).toEqual({
      tone: "error",
      text: "t40 running · 1 blocked · 1 queued",
    });
  });
});

describe("deploy", () => {
  const now = Date.parse("2026-11-06T15:00:00Z");
  const reports: M.Report[] = [
    {
      time: "2026-11-06T14:58:00Z",
      state: "working",
      id: "switch/evaluate",
      msg: "Evaluating asus",
      run: "r1",
    },
    {
      time: "2026-11-06T14:58:20Z",
      state: "done",
      id: "switch/evaluate",
      msg: "Evaluated asus",
      run: "r1",
    },
  ];
  const generation: M.Generation = {
    at: "2026-11-06T14:00:00Z",
    host: "asus",
    outcome: "unchanged",
    generation: 257,
    rev: "19272fce",
  };

  test("a switch without its final report is running", () => {
    const state = M.deployState(reports, [generation], [], now);
    expect(state).toMatchObject({ running: true, stale: false });
    expect(state.run).toHaveLength(2);
    expect(M.summarizeDeploy(state, now)).toEqual({
      tone: "busy",
      text: "switching · ✓ switch/evaluate: Evaluated asus",
    });
  });

  test("the top-level report ends a switch", () => {
    const final = [
      ...reports,
      {
        time: "2026-11-06T14:58:21Z",
        state: "done",
        id: "switch",
        msg: "No generation created",
        run: "r1",
      },
    ];
    const state = M.deployState(final, [generation], [], now);
    expect(state.running).toBe(false);
    expect(M.summarizeDeploy(state, now)).toEqual({
      tone: "ok",
      text: "gen 257 unchanged · 1m 39s ago",
    });
  });

  test("a report an hour old without a final one is stale", () => {
    expect(M.deployState(reports, [], [], now + 2 * 60 * 60_000)).toMatchObject(
      { running: false, stale: true },
    );
  });

  test("a revert newer than the last generation is the host's state", () => {
    const revert: M.Revert = {
      id: "x",
      at: "2026-11-06T14:30:00Z",
      host: "asus",
      phase: "activation",
      rev: "b0b822eed10a",
      breached: ["activation"],
    };
    const final = [
      ...reports,
      { time: "2026-11-06T14:58:21Z", state: "done", id: "switch", run: "r1" },
    ];
    const state = {
      ...M.deployState(final, [generation], [revert], now),
      repository: "o/r",
    };
    expect(M.summarizeDeploy(state, now)).toEqual({
      tone: "error",
      text: "reverted b0b822ee · 30m 00s ago",
    });
    expect(
      M.deployRows(state, now).find((row) => row.key === "deploy:revert"),
    ).toMatchObject({
      tone: "error",
      url: "https://github.com/o/r/commit/b0b822eed10a",
    });
  });
});

test("durations stay short", () => {
  expect(
    [12_000, 245_000, 3_720_000, 3 * 86_400_000 + 4 * 3_600_000].map(
      M.duration,
    ),
  ).toEqual(["12s", "4m 05s", "1h 02m", "3d 4h"]);
});
