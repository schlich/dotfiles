// Parsing and summaries for the workflow-status plugin. Nothing here spawns a
// process, reads a file, or imports OpenCode, so model.test.ts runs it under
// plain `bun test`.

export type Tone = "ok" | "warn" | "error" | "busy" | "idle";

const severity: Readonly<Record<Tone, number>> = {
  idle: 0,
  ok: 1,
  busy: 2,
  warn: 3,
  error: 4,
};

/** The tone that needs the most attention. */
export function worst(tones: readonly Tone[]): Tone {
  return tones.reduce<Tone>(
    (result, tone) => (severity[tone] > severity[result] ? tone : result),
    "idle",
  );
}

export const glyph: Readonly<Record<Tone, string>> = {
  ok: "✓",
  warn: "!",
  error: "✗",
  busy: "●",
  idle: "·",
};

/** One selectable line in a section of the workflow panel. */
export interface Row {
  readonly key: string;
  readonly tone: Tone;
  readonly label: string;
  readonly detail?: string;
  /** What `o` opens and `y` copies. */
  readonly url?: string;
  /** What `y` copies when the row has no URL. */
  readonly copy?: string;
  /** The body of the row's DETAIL view. */
  readonly lines?: readonly string[];
}

/** A section's state in one line, for the sidebar and the home footer. */
export interface Summary {
  readonly tone: Tone;
  readonly text: string;
}

// ---- Helpers ---------------------------------------------------------------

export function basename(file: string): string {
  const trimmed = file.replace(/\/+$/, "");
  return trimmed.slice(trimmed.lastIndexOf("/") + 1) || trimmed;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function time(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return undefined;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

/** A short elapsed time: 12s, 4m 05s, 1h 02m, 3d 4h. */
export function duration(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60)
    return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ${String(minutes % 60).padStart(2, "0")}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

/** When a SCRU128 id, such as a cross.stream frame id, was minted: its top 48 bits, in ms. */
export function scru128Time(id: string): number | undefined {
  if (!/^[0-9a-z]{25}$/i.test(id)) return undefined;
  let value = 0n;
  for (const char of id.toLowerCase())
    value = value * 36n + BigInt(Number.parseInt(char, 36));
  return Number(value >> 80n);
}

/** JSON Lines, skipping lines that are not JSON objects, such as one cut mid-write. */
export function parseJsonLines<T = Record<string, unknown>>(
  input: string,
): T[] {
  return input.split("\n").flatMap((line) => {
    if (!line.trim()) return [];
    try {
      const value: unknown = JSON.parse(line);
      return value !== null &&
        typeof value === "object" &&
        !Array.isArray(value)
        ? [value as T]
        : [];
    } catch {
      return [];
    }
  });
}

/** A field of a NUON record such as `LOG.job.nuon`; simple NUON strings are bare words. */
export function nuonField(input: string, field: string): string | undefined {
  const match = new RegExp(
    `(?:^|[{,\\s])${field}:\\s*(?:"((?:[^"\\\\]|\\\\.)*)"|([^,}\\s]+))`,
  ).exec(input);
  if (!match) return undefined;
  if (match[1] === undefined) return match[2];
  try {
    return JSON.parse(`"${match[1]}"`) as string;
  } catch {
    return match[1];
  }
}

// ---- Git -------------------------------------------------------------------

export interface GitStatus {
  readonly oid?: string;
  /** Undefined while HEAD is detached. */
  readonly branch?: string;
  readonly upstream?: string;
  readonly ahead: number;
  readonly behind: number;
  readonly staged: number;
  readonly unstaged: number;
  readonly untracked: number;
  readonly conflicted: number;
}

/** `git status --porcelain=v2 --branch`. */
export function parseGitStatus(input: string): GitStatus {
  let oid: string | undefined;
  let branch: string | undefined;
  let upstream: string | undefined;
  let ahead = 0;
  let behind = 0;
  let staged = 0;
  let unstaged = 0;
  let untracked = 0;
  let conflicted = 0;
  for (const line of input.split("\n")) {
    if (line.startsWith("# branch.oid ")) {
      const value = line.slice("# branch.oid ".length);
      if (value !== "(initial)") oid = value;
    } else if (line.startsWith("# branch.head ")) {
      const value = line.slice("# branch.head ".length);
      if (value !== "(detached)") branch = value;
    } else if (line.startsWith("# branch.upstream ")) {
      upstream = line.slice("# branch.upstream ".length);
    } else if (line.startsWith("# branch.ab ")) {
      const match = /^\+(\d+) -(\d+)$/.exec(line.slice("# branch.ab ".length));
      if (match) {
        ahead = Number(match[1]);
        behind = Number(match[2]);
      }
    } else if (line.startsWith("1 ") || line.startsWith("2 ")) {
      // XY: the index's status, then the work tree's; "." is unchanged.
      if (line[2] !== ".") staged++;
      if (line[3] !== ".") unstaged++;
    } else if (line.startsWith("u ")) {
      conflicted++;
    } else if (line.startsWith("? ")) {
      untracked++;
    }
  }
  return {
    oid,
    branch,
    upstream,
    ahead,
    behind,
    staged,
    unstaged,
    untracked,
    conflicted,
  };
}

// ---- Jujutsu ---------------------------------------------------------------

const JJ_FIELDS = [
  'if(current_working_copy, "@", "-")',
  'if(self.contained_in("trunk()..@ ~ empty()"), "1", "0")',
  "change_id.shortest(8)",
  "commit_id.short(8)",
  'if(empty, "1", "0")',
  'if(conflict, "1", "0")',
  'if(divergent, "1", "0")',
  'local_bookmarks.map(|b| b.name()).join(",")',
  // Last, so a tab inside a description cannot shift the other fields.
  "description.first_line()",
];

/** `jj log -T`: one tab-separated line per commit. */
export const JJ_TEMPLATE = JJ_FIELDS.join(' ++ "\\t" ++ ') + ' ++ "\\n"';
/** The working copy, its nearest bookmarked ancestor, and the non-empty commits ahead of trunk. */
export const JJ_REVSET =
  "@ | heads(::@ & bookmarks()) | (trunk()..@ ~ empty())";
export const JJ_LIMIT = 100;

export interface JjChange {
  readonly changeId: string;
  readonly commitId: string;
  readonly empty: boolean;
  readonly conflict: boolean;
  readonly divergent: boolean;
  readonly bookmarks: readonly string[];
  readonly description: string;
}

export interface JjStatus {
  readonly change: JjChange;
  /** Non-empty commits between trunk and the working copy. */
  readonly ahead: number;
  /** The bookmarks of the working copy's nearest bookmarked ancestor, itself included. */
  readonly bookmarks: readonly string[];
  /** The log reached its limit, so `ahead` is a lower bound. */
  readonly truncated: boolean;
}

export function parseJjLog(
  input: string,
  limit = JJ_LIMIT,
): JjStatus | undefined {
  const lines = input.split("\n").filter((line) => line.length > 0);
  const commits = lines.map((line) => {
    const [
      current,
      ahead,
      changeId = "",
      commitId = "",
      empty,
      conflict,
      divergent,
      bookmarks = "",
      ...description
    ] = line.split("\t");
    return {
      current: current === "@",
      ahead: ahead === "1",
      change: {
        changeId,
        commitId,
        empty: empty === "1",
        conflict: conflict === "1",
        divergent: divergent === "1",
        bookmarks: bookmarks ? bookmarks.split(",") : [],
        description: description.join("\t"),
      },
    };
  });
  const working = commits.find((commit) => commit.current);
  if (!working) return undefined;
  return {
    change: working.change,
    ahead: commits.filter((commit) => commit.ahead).length,
    bookmarks:
      commits.find((commit) => commit.change.bookmarks.length > 0)?.change
        .bookmarks ?? [],
    truncated: lines.length >= limit,
  };
}

/** Commit ids of the working copy's ancestors that have remote bookmarks, newest first. */
export const JJ_PUSHED_TEMPLATE =
  'commit_id ++ "\\t" ++ remote_bookmarks.map(|b| b.name() ++ "@" ++ b.remote()).join(",") ++ "\\n"';
export const JJ_PUSHED_REVSET = "::@ & remote_bookmarks()";

/**
 * The newest ancestor a real remote has. In a colocated repository every local
 * bookmark also has a `@git` remote bookmark, which says nothing about pushes.
 */
export function parseJjPushed(
  input: string,
): { readonly commit: string; readonly refs: readonly string[] } | undefined {
  for (const line of input.split("\n")) {
    const [commit, refs = ""] = line.split("\t");
    if (!commit) continue;
    const remote = refs
      .split(",")
      .filter((ref) => ref.length > 0 && !ref.endsWith("@git"));
    if (remote.length > 0) return { commit, refs: remote };
  }
  return undefined;
}

// ---- Remotes ---------------------------------------------------------------

export interface Remote {
  readonly name: string;
  readonly url: string;
}

/** `git config --get-regexp '^remote\..*\.url$'`, or `jj git remote list`. */
export function parseRemotes(input: string): Remote[] {
  return input.split("\n").flatMap((line) => {
    const [key, url] = line.trim().split(/\s+/);
    if (!key || !url) return [];
    return [{ name: /^remote\.(.+)\.url$/.exec(key)?.[1] ?? key, url }];
  });
}

export function githubSlug(url: string): string | undefined {
  const match = /github\.com[:/]+([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(
    url.trim(),
  );
  return match ? `${match[1]}/${match[2]}` : undefined;
}

/** The GitHub repository CI reports to: origin's, or else the first GitHub remote's. */
export function githubRepository(
  remotes: readonly Remote[],
): string | undefined {
  const ordered = [...remotes].sort(
    (a, b) => Number(b.name === "origin") - Number(a.name === "origin"),
  );
  for (const remote of ordered) {
    const slug = githubSlug(remote.url);
    if (slug) return slug;
  }
  return undefined;
}

// ---- Version control summary -----------------------------------------------

export interface VcsData {
  readonly kind: "jj" | "git" | "none";
  readonly root: string;
  readonly git?: GitStatus;
  readonly jj?: JjStatus;
  /** The upstream's commit while HEAD is ahead of it, which is what CI last saw. */
  readonly upstreamOid?: string;
  /** JJ and Git share the working copy, so Git's status shows its live edits. */
  readonly colocated?: boolean;
  /** A linked Git worktree. */
  readonly worktree?: boolean;
  /** The repository opted into the `ci` trunk workflow. */
  readonly ci?: boolean;
}

function dirty(git: GitStatus | undefined): number {
  return git ? git.staged + git.unstaged + git.conflicted + git.untracked : 0;
}

export function summarizeVcs(data: VcsData): Summary {
  if (data.kind === "jj" && data.jj) {
    const { change, ahead, bookmarks, truncated } = data.jj;
    const edits = dirty(data.git);
    return {
      tone: change.conflict ? "error" : change.divergent ? "warn" : "ok",
      text: [
        `@ ${change.changeId}`,
        bookmarks[0],
        ahead > 0 ? `↑${ahead}${truncated ? "+" : ""}` : undefined,
        edits > 0 ? `±${edits}` : undefined,
        change.conflict ? "conflict" : undefined,
        change.divergent ? "divergent" : undefined,
      ]
        .filter(Boolean)
        .join(" "),
    };
  }
  if (data.kind === "git" && data.git) {
    const git = data.git;
    const edits = dirty(git);
    return {
      tone: git.conflicted > 0 ? "error" : git.behind > 0 ? "warn" : "ok",
      text: [
        `⎇ ${git.branch ?? `detached ${git.oid?.slice(0, 8) ?? ""}`.trim()}`,
        git.ahead > 0 ? `↑${git.ahead}` : undefined,
        git.behind > 0 ? `↓${git.behind}` : undefined,
        edits > 0 ? `±${edits}` : undefined,
        git.conflicted > 0 ? `${git.conflicted} conflicted` : undefined,
      ]
        .filter(Boolean)
        .join(" "),
    };
  }
  return { tone: "idle", text: "no repository" };
}

function changeRows(git: GitStatus, key: string): Row[] {
  const total = dirty(git);
  return [
    {
      key: `${key}:changes`,
      tone: git.conflicted > 0 ? "error" : total > 0 ? "busy" : "ok",
      label:
        total === 0
          ? "working tree clean"
          : [
              git.staged ? `${git.staged} staged` : undefined,
              git.unstaged ? `${git.unstaged} modified` : undefined,
              git.untracked ? `${git.untracked} untracked` : undefined,
              git.conflicted ? `${git.conflicted} conflicted` : undefined,
            ]
              .filter(Boolean)
              .join(" · "),
    },
  ];
}

export function vcsRows(data: VcsData): Row[] {
  if (data.kind === "jj" && data.jj) {
    const { change, ahead, bookmarks, truncated } = data.jj;
    const rows: Row[] = [
      {
        key: "jj:change",
        tone: change.conflict ? "error" : change.divergent ? "warn" : "ok",
        label: `@ ${change.changeId} ${change.description || "(no description)"}`,
        detail: [
          change.commitId,
          change.empty ? "empty" : undefined,
          change.conflict ? "conflict" : undefined,
          change.divergent ? "divergent" : undefined,
        ]
          .filter(Boolean)
          .join(" · "),
        copy: change.changeId,
        lines: [
          `change ${change.changeId} · commit ${change.commitId}`,
          change.description || "(no description)",
          ...(change.empty ? ["The working-copy commit is empty."] : []),
          ...(change.conflict
            ? ["The working-copy commit has conflicts."]
            : []),
          ...(change.divergent
            ? [
                "The change is divergent: more than one visible commit has its change id.",
              ]
            : []),
          "As of the last JJ operation; this view never snapshots the working copy.",
        ],
      },
      {
        key: "jj:bookmarks",
        tone: "idle",
        label:
          bookmarks.length > 0
            ? `bookmarks: ${bookmarks.join(", ")}`
            : "no bookmarks on @ or its ancestors",
        detail: `${ahead}${truncated ? "+" : ""} commit${ahead === 1 ? "" : "s"} ahead of trunk`,
        copy: bookmarks[0],
      },
    ];
    if (data.git) rows.push(...changeRows(data.git, "jj"));
    if (data.ci)
      rows.push({
        key: "jj:ci",
        tone: "idle",
        label: "ci workflow enabled",
        detail: "ci status in a terminal",
      });
    return rows;
  }
  if (data.kind === "git" && data.git) {
    const git = data.git;
    const head = git.branch ?? `detached at ${git.oid?.slice(0, 8) ?? "?"}`;
    return [
      {
        key: "git:branch",
        tone: git.behind > 0 ? "warn" : "ok",
        label: `⎇ ${head}`,
        detail: git.upstream
          ? `${git.upstream} ↑${git.ahead} ↓${git.behind}`
          : "no upstream",
        copy: git.branch ?? git.oid,
        lines: [
          `HEAD ${git.oid ?? "(no commits)"}`,
          git.upstream
            ? `upstream ${git.upstream}: ${git.ahead} ahead, ${git.behind} behind`
            : "No upstream is set.",
          ...(data.worktree ? [`A linked worktree at ${data.root}`] : []),
        ],
      },
      ...changeRows(git, "git"),
    ];
  }
  return [
    { key: "none", tone: "idle", label: "not in a Git or JJ repository" },
  ];
}

// ---- CI --------------------------------------------------------------------

export type CheckState = "running" | "failed" | "warn" | "passed" | "skipped";

export interface Check {
  readonly name: string;
  readonly app: string;
  readonly state: CheckState;
  readonly status: string;
  readonly conclusion?: string;
  readonly url?: string;
  readonly started?: number;
  readonly completed?: number;
  readonly summary?: string;
  /** nixbot's checks gate `main`; GitHub Actions only reports. */
  readonly gate: boolean;
}

export function checkState(
  status: string,
  conclusion: string | undefined,
  name: string,
): CheckState {
  if (status !== "completed") return "running";
  switch (conclusion) {
    case "success":
    case "neutral":
      return "passed";
    case "skipped":
    case "stale":
      return "skipped";
    case "cancelled":
      return "warn";
    default:
      // Remote checks such as the desktop closure build report without blocking a landing.
      return /non-blocking/i.test(name) ? "warn" : "failed";
  }
}

function isGate(app: string, name: string): boolean {
  return app.startsWith("nixbot") || name.startsWith("nixbot/");
}

/** GitHub's `commits/SHA/check-runs` response: GitHub Actions jobs and nixbot's checks. */
export function parseCheckRuns(input: unknown): Check[] {
  const runs = record(input).check_runs;
  if (!Array.isArray(runs)) return [];
  return runs.map((item) => {
    const run = record(item);
    const app = record(run.app);
    const name = text(run.name) ?? "check";
    const appName = text(app.slug) ?? text(app.name) ?? "";
    const status = text(run.status) ?? "queued";
    const conclusion = text(run.conclusion);
    return {
      name,
      app: appName,
      status,
      conclusion,
      state: checkState(status, conclusion, name),
      url: text(run.html_url) ?? text(run.details_url),
      started: time(run.started_at),
      completed: time(run.completed_at),
      summary: text(record(run.output).title),
      gate: isGate(appName, name),
    };
  });
}

/** GitHub's `commits/SHA/status` response: commit statuses, which some apps report instead. */
export function parseStatuses(input: unknown): Check[] {
  const statuses = record(input).statuses;
  if (!Array.isArray(statuses)) return [];
  return statuses.map((item) => {
    const status = record(item);
    const name = text(status.context) ?? "status";
    const state = text(status.state) ?? "pending";
    const running = state === "pending";
    const conclusion = running
      ? undefined
      : state === "success"
        ? "success"
        : "failure";
    return {
      name,
      app: "status",
      status: running ? "in_progress" : "completed",
      conclusion,
      state: checkState(
        running ? "in_progress" : "completed",
        conclusion,
        name,
      ),
      url: text(status.target_url),
      started: time(status.created_at),
      completed: running ? undefined : time(status.updated_at),
      summary: text(status.description),
      gate: isGate("", name),
    };
  });
}

export interface PullRequest {
  readonly number: number;
  readonly title: string;
  readonly url: string;
  readonly state: string;
  readonly draft: boolean;
}

/** GitHub's `commits/SHA/pulls` response. */
export function parsePulls(input: unknown): PullRequest[] {
  if (!Array.isArray(input)) return [];
  return input.flatMap((item) => {
    const pull = record(item);
    const id = number(pull.number);
    const url = text(pull.html_url);
    if (id === undefined || !url) return [];
    return [
      {
        number: id,
        title: text(pull.title) ?? "",
        url,
        state: text(pull.state) ?? "open",
        draft: pull.draft === true,
      },
    ];
  });
}

export type CheckCounts = Readonly<Record<CheckState, number>>;

export function countChecks(checks: readonly Check[]): CheckCounts {
  const counts = { running: 0, failed: 0, warn: 0, passed: 0, skipped: 0 };
  for (const check of checks) counts[check.state]++;
  return counts;
}

/** The state of the checks that gate `main`, when there are any. */
export function gateState(checks: readonly Check[]): CheckState | undefined {
  const gates = checks.filter((check) => check.gate);
  if (gates.length === 0) return undefined;
  const counts = countChecks(gates);
  if (counts.failed > 0) return "failed";
  if (counts.running > 0) return "running";
  if (counts.warn > 0) return "warn";
  return counts.passed > 0 ? "passed" : "skipped";
}

const checkGlyph: Readonly<Record<CheckState, string>> = {
  running: "●",
  failed: "✗",
  warn: "!",
  passed: "✓",
  skipped: "–",
};
const checkTone: Readonly<Record<CheckState, Tone>> = {
  running: "busy",
  failed: "error",
  warn: "warn",
  passed: "ok",
  skipped: "idle",
};

export function summarizeChecks(checks: readonly Check[]): Summary {
  if (checks.length === 0) return { tone: "idle", text: "no checks yet" };
  const counts = countChecks(checks);
  const gate = gateState(checks);
  return {
    tone:
      counts.failed > 0
        ? "error"
        : counts.running > 0
          ? "busy"
          : counts.warn > 0
            ? "warn"
            : "ok",
    text: [
      gate ? `nixbot ${checkGlyph[gate]}` : undefined,
      counts.failed ? `${counts.failed} failed` : undefined,
      counts.running ? `${counts.running} running` : undefined,
      counts.warn && !counts.failed
        ? `${counts.warn} warning${counts.warn === 1 ? "" : "s"}`
        : undefined,
      counts.passed ? `${counts.passed} passed` : undefined,
    ]
      .filter(Boolean)
      .join(" · "),
  };
}

export function failingNames(checks: readonly Check[]): string {
  const names = checks
    .filter((check) => check.state === "failed")
    .map((check) => check.name);
  return names.length > 3
    ? `${names.slice(0, 3).join(", ")} and ${names.length - 3} more`
    : names.join(", ");
}

function appLabel(check: Check): string {
  if (check.gate) return "nixbot gate";
  if (check.app === "github-actions") return "Actions";
  return check.app;
}

const checkOrder: Readonly<Record<CheckState, number>> = {
  failed: 0,
  running: 1,
  warn: 2,
  passed: 3,
  skipped: 4,
};

export interface CiView {
  readonly slug?: string;
  readonly sha?: string;
  /** What the checks belong to: a branch, remote bookmarks, or why there are none. */
  readonly target: string;
  readonly checks: readonly Check[];
  readonly pulls: readonly PullRequest[];
}

export function ciRows(data: CiView, now: number): Row[] {
  const rows: Row[] = [
    {
      key: "ci:target",
      tone: "idle",
      label: data.sha
        ? `${data.target} @ ${data.sha.slice(0, 8)}`
        : data.target,
      detail: data.slug,
      url:
        data.slug && data.sha
          ? `https://github.com/${data.slug}/commit/${data.sha}`
          : undefined,
      copy: data.sha,
    },
  ];
  for (const pull of data.pulls) {
    rows.push({
      key: `ci:pull:${pull.number}`,
      tone: pull.state === "open" ? "ok" : "idle",
      label: `#${pull.number} ${pull.title}`,
      detail: pull.draft ? "draft" : pull.state,
      url: pull.url,
    });
  }
  const sorted = [...data.checks].sort(
    (a, b) =>
      checkOrder[a.state] - checkOrder[b.state] ||
      Number(b.gate) - Number(a.gate) ||
      a.name.localeCompare(b.name),
  );
  sorted.forEach((check, index) => {
    const took =
      check.started === undefined
        ? undefined
        : duration((check.completed ?? now) - check.started);
    rows.push({
      key: `ci:check:${index}:${check.name}`,
      tone: checkTone[check.state],
      label: check.name,
      detail: [
        appLabel(check),
        check.state === "running"
          ? check.status.replaceAll("_", " ")
          : check.conclusion,
        took,
      ]
        .filter(Boolean)
        .join(" · "),
      url: check.url,
      lines: [
        `${check.name} (${appLabel(check)})`,
        `status ${check.status}${check.conclusion ? `, conclusion ${check.conclusion}` : ""}`,
        ...(took
          ? [`${check.state === "running" ? "running for" : "took"} ${took}`]
          : []),
        ...(check.summary ? [check.summary] : []),
        ...(check.url ? [check.url] : []),
      ],
    });
  });
  return rows;
}

// ---- Background jobs -------------------------------------------------------

export type JobState = "running" | "done" | "failed" | "lost";
export type JobKind = "job" | "ci" | "claude" | "opencode";

export interface Job {
  readonly id: string;
  readonly kind: JobKind;
  readonly label: string;
  readonly state: JobState;
  readonly cwd?: string;
  readonly started?: number;
  readonly finished?: number;
  readonly exit?: number;
  readonly error?: string;
  /** The latest progress report from `LOG.status.jsonl`. */
  readonly phase?: string;
  readonly log?: string;
  /** The process that owns the job; its exit without a result loses the job. */
  readonly pid?: number;
  /** A ci MCP job runs in this systemd unit, so its owner's exit does not end it. */
  readonly unit?: string;
}

export interface Frame {
  readonly topic: string;
  readonly id: string;
  readonly meta?: unknown;
  readonly timestamp?: string;
}

const ciJob = /^\d{8}T\d{6}-([a-z][a-z-]*)-[0-9a-f]+$/;

/** Records a job's result, from a `done` frame's outcome or a `LOG.done.nuon` file. */
export function finishJob(
  job: Job,
  outcome: unknown,
  at: number | undefined,
): Job {
  const result = record(outcome);
  const exit = number(result.exit_code);
  return {
    ...job,
    finished: at ?? job.finished,
    exit,
    error: text(result.error),
    state: exit === 0 ? "done" : "failed",
  };
}

/**
 * Folds one cross.stream frame into `jobs`: `job-log` and the ci MCP server
 * announce `job.ID.start` and `job.ID.done`. Returns the job it changed.
 */
export function applyFrame(
  jobs: Map<string, Job>,
  frame: Frame,
): Job | undefined {
  const match = /^job\.(.+)\.(start|done)$/.exec(frame.topic);
  if (!match) return undefined;
  const id = match[1]!;
  const meta = record(frame.meta);
  const at = time(frame.timestamp) ?? scru128Time(frame.id);
  const ci = ciJob.exec(id);
  const previous: Job = jobs.get(id) ?? {
    id,
    kind: ci ? "ci" : "job",
    label: ci ? `ci ${ci[1]}` : "job",
    state: "running",
  };
  let next: Job;
  if (match[2] === "start") {
    const log = text(meta.log) ?? previous.log;
    next = {
      ...previous,
      started: at ?? previous.started,
      cwd: text(meta.cwd) ?? previous.cwd,
      log,
      pid: number(meta.pid) ?? previous.pid,
      unit: text(meta.unit) ?? previous.unit,
      // Until the job's record names its command, its log names it.
      label:
        previous.label === "job" && log
          ? basename(log).replace(/\.log$/, "")
          : previous.label,
    };
  } else {
    next = finishJob(previous, meta.outcome, at);
  }
  jobs.set(id, next);
  return next;
}

export interface Report {
  readonly state?: string;
  readonly id?: string;
  readonly msg?: string;
  readonly time?: string;
  readonly run?: string;
  readonly progress?: number;
}

const reportGlyph: Readonly<Record<string, string>> = {
  working: "▶",
  done: "✓",
  failed: "✗",
  blocked: "⏸",
};

function describeReport(report: Report): string {
  const progress = number(report.progress);
  const head = [
    reportGlyph[report.state ?? ""] ?? report.state,
    report.id,
    progress !== undefined ? `${progress}%` : undefined,
  ]
    .filter(Boolean)
    .join(" ");
  return report.msg ? `${head}: ${report.msg}` : head;
}

/** The latest OSC 7501 report a job wrote to `LOG.status.jsonl`, as watch-job prints it. */
export function latestPhase(reports: readonly Report[]): string | undefined {
  const report = [...reports]
    .reverse()
    .find((item) => item.state !== undefined && item.state !== "clear");
  return report ? describeReport(report) : undefined;
}

/** Claude Code's background tasks, as the agent-tasks hook records them for Fieldnotes. */
export function claudeJobs(records: readonly unknown[]): Job[] {
  return records.flatMap((item): Job[] => {
    const task = record(item);
    // A report pushed from another host holds that host's tasks.
    if (Array.isArray(task.tasks)) {
      const host = text(task.host) ?? "remote";
      return claudeJobs(task.tasks).map((job) => ({
        ...job,
        id: `${host}:${job.id}`,
        label: `${job.label} (${host})`,
      }));
    }
    const id = text(task.id);
    if (!id) return [];
    const finished = time(task.finished);
    return [
      {
        id: `claude:${id}`,
        kind: "claude",
        label: text(task.description) ?? id,
        cwd: text(task.cwd),
        started: time(task.started),
        finished,
        state: finished === undefined ? "running" : "done",
      },
    ];
  });
}

/** The fields of an OpenCode shell (Shell.Info) this view reads. */
export interface ShellLike {
  readonly id: string;
  readonly status: string;
  readonly command: string;
  readonly cwd: string;
  readonly exit?: number;
  readonly time: { readonly started: number; readonly completed?: number };
}

export function shellJob(shell: ShellLike): Job {
  return {
    id: `opencode:${shell.id}`,
    kind: "opencode",
    label: shell.command,
    cwd: shell.cwd,
    started: shell.time.started,
    finished: shell.time.completed,
    exit: shell.exit,
    state:
      shell.status === "running"
        ? "running"
        : shell.status === "exited" && shell.exit === 0
          ? "done"
          : "failed",
  };
}

/** Finished jobs stay in view this long. */
export const RECENT = 30 * 60_000;

const jobOrder: Readonly<Record<JobState, number>> = {
  running: 0,
  failed: 1,
  lost: 1,
  done: 2,
};
const jobTone: Readonly<Record<JobState, Tone>> = {
  running: "busy",
  done: "ok",
  failed: "error",
  lost: "error",
};
const kindName: Readonly<Record<JobKind, string>> = {
  job: "job",
  ci: "ci",
  claude: "claude",
  opencode: "shell",
};

export function visibleJobs(jobs: readonly Job[], now: number): Job[] {
  return jobs
    .filter(
      (job) =>
        job.state === "running" ||
        (job.finished ?? job.started ?? 0) >= now - RECENT,
    )
    .sort(
      (a, b) =>
        jobOrder[a.state] - jobOrder[b.state] ||
        (a.state === "running"
          ? (a.started ?? 0) - (b.started ?? 0)
          : (b.finished ?? 0) - (a.finished ?? 0)),
    );
}

function jobDetail(job: Job, now: number): string {
  const where = job.cwd ? basename(job.cwd) : undefined;
  if (job.state === "running")
    return [
      kindName[job.kind],
      job.phase,
      job.started !== undefined ? duration(now - job.started) : undefined,
      where,
    ]
      .filter(Boolean)
      .join(" · ");
  const outcome =
    job.state === "lost"
      ? "lost"
      : job.exit !== undefined
        ? `exit ${job.exit}`
        : job.state;
  const when =
    job.finished !== undefined
      ? `${duration(now - job.finished)} ago`
      : undefined;
  return [kindName[job.kind], outcome, when, where].filter(Boolean).join(" · ");
}

export function jobRows(jobs: readonly Job[], now: number): Row[] {
  return visibleJobs(jobs, now).map((job) => ({
    key: `job:${job.id}`,
    tone: jobTone[job.state],
    label: job.label,
    detail: jobDetail(job, now),
    copy: job.log ?? job.cwd,
    lines: [
      job.label,
      `${kindName[job.kind]} · ${job.state}${job.exit !== undefined ? ` · exit ${job.exit}` : ""}`,
      ...(job.phase ? [job.phase] : []),
      ...(job.error ? [job.error] : []),
      ...(job.cwd ? [`in ${job.cwd}`] : []),
      ...(job.started !== undefined
        ? [`started ${new Date(job.started).toLocaleString()}`]
        : []),
      ...(job.finished !== undefined
        ? [`finished ${new Date(job.finished).toLocaleString()}`]
        : []),
      ...(job.log ? [`log ${job.log}`] : []),
      ...(job.state === "lost" ? ["Its owner exited without a result."] : []),
    ],
  }));
}

export function summarizeJobs(jobs: readonly Job[], now: number): Summary {
  const visible = visibleJobs(jobs, now);
  const running = visible.filter((job) => job.state === "running").length;
  const failed = visible.filter(
    (job) => job.state === "failed" || job.state === "lost",
  ).length;
  if (visible.length === 0)
    return { tone: "idle", text: "none in the last 30 min" };
  return {
    tone: failed > 0 ? "error" : running > 0 ? "busy" : "ok",
    text:
      [
        running ? `${running} running` : undefined,
        failed ? `${failed} failed` : undefined,
      ]
        .filter(Boolean)
        .join(" · ") || `${visible.length} done`,
  };
}

// ---- luvus tasks -----------------------------------------------------------

export interface Task {
  readonly id: string;
  readonly title: string;
  readonly status: string;
  readonly branch?: string;
  readonly worktree?: string;
  readonly gate?: string;
  readonly notes: readonly string[];
  /** The project the task belongs to: its checkout, or that checkout's `.git`. */
  readonly root?: string;
  readonly updated?: number;
}

/** `luvus task list --json`. */
export function parseTasks(input: unknown): Task[] {
  const tasks = record(record(input).result).tasks;
  if (!Array.isArray(tasks)) return [];
  return tasks.flatMap((item) => {
    const task = record(item);
    const id = text(task.id);
    if (!id) return [];
    const notes = Array.isArray(task.notes)
      ? task.notes.filter((note): note is string => typeof note === "string")
      : [];
    return [
      {
        id,
        title: text(task.title) ?? "",
        status: text(task.status) ?? "unknown",
        branch: text(task.branch),
        worktree: text(task.worktree),
        gate: text(task.gate),
        notes,
        root: text(record(task.project).root),
        updated: number(task.updated),
      },
    ];
  });
}

export function projectRoot(root: string): string {
  return root.replace(/\/+$/, "").replace(/\/\.git$/, "");
}

export function projectTasks(tasks: readonly Task[], root: string): Task[] {
  const wanted = projectRoot(root);
  return tasks.filter(
    (task) => task.root !== undefined && projectRoot(task.root) === wanted,
  );
}

const finishedStatus = new Set(["done", "merged", "cancelled"]);
const statusOrder: Readonly<Record<string, number>> = {
  blocked: 0,
  failed: 0,
  review: 1,
  running: 2,
  claimed: 3,
  queued: 4,
};

export function taskTone(status: string): Tone {
  switch (status) {
    case "blocked":
    case "failed":
      return "error";
    case "review":
      return "warn";
    case "running":
    case "claimed":
      return "busy";
    case "done":
    case "merged":
      return "ok";
    default:
      return "idle";
  }
}

/**
 * The task this checkout works on: the one whose worktree it is, or whose
 * branch it has. A worktree made with `luvus worktree create luvus/ID` leaves
 * the task without a branch, so its `luvus/ID` branch names it too.
 */
export function currentTask(
  tasks: readonly Task[],
  here: { readonly root?: string; readonly branch?: string },
): Task | undefined {
  return (
    tasks.find(
      (task) =>
        here.root !== undefined &&
        task.worktree !== undefined &&
        projectRoot(task.worktree) === projectRoot(here.root),
    ) ??
    tasks.find(
      (task) =>
        here.branch !== undefined &&
        (task.branch === here.branch || here.branch === `luvus/${task.id}`),
    )
  );
}

export interface TaskView {
  readonly tasks: readonly Task[];
  readonly current?: Task;
}

export function activeTasks(data: TaskView): Task[] {
  return data.tasks
    .filter(
      (task) =>
        !finishedStatus.has(task.status) && task.id !== data.current?.id,
    )
    .sort(
      (a, b) =>
        (statusOrder[a.status] ?? 5) - (statusOrder[b.status] ?? 5) ||
        Number(a.id.replace(/\D/g, "")) - Number(b.id.replace(/\D/g, "")),
    );
}

function taskRow(task: Task, here: boolean): Row {
  return {
    key: `task:${task.id}`,
    tone: taskTone(task.status),
    label: `${here ? "◆ " : ""}${task.id} ${task.title}`,
    detail: [task.status, task.branch].filter(Boolean).join(" · "),
    copy: task.worktree ?? task.id,
    lines: [
      `${task.id} ${task.title}`,
      `status ${task.status}${here ? " · this checkout's task" : ""}`,
      ...(task.branch ? [`branch ${task.branch}`] : []),
      ...(task.worktree ? [`worktree ${task.worktree}`] : []),
      ...(task.gate ? [`gate ${task.gate}`] : []),
      ...task.notes,
    ],
  };
}

export function taskRows(data: TaskView): Row[] {
  return [
    ...(data.current ? [taskRow(data.current, true)] : []),
    ...activeTasks(data).map((task) => taskRow(task, false)),
  ];
}

export function summarizeTasks(data: TaskView): Summary {
  const active = activeTasks(data);
  const counts = new Map<string, number>();
  for (const task of active)
    counts.set(task.status, (counts.get(task.status) ?? 0) + 1);
  const others = [...counts.entries()]
    .sort(([a], [b]) => (statusOrder[a] ?? 5) - (statusOrder[b] ?? 5))
    .map(([status, count]) => `${count} ${status}`);
  const parts = [
    data.current ? `${data.current.id} ${data.current.status}` : undefined,
    ...others,
  ].filter(Boolean);
  return {
    tone: worst([
      ...(data.current ? [taskTone(data.current.status)] : []),
      ...active.map((task) =>
        taskTone(task.status) === "error" ? "error" : "idle",
      ),
    ]),
    text: parts.length > 0 ? parts.join(" · ") : "no open tasks",
  };
}

// ---- Staged NixOS switch ---------------------------------------------------

export interface Generation {
  readonly at?: string;
  readonly host?: string;
  readonly outcome?: string;
  readonly rev?: string;
  readonly subject?: string;
  readonly generation?: number;
  readonly toplevel?: string;
}

/** A staged switch the host's health checks reverted, from `reverts.jsonl`. */
export interface Revert {
  readonly id?: string;
  readonly at?: string;
  readonly host?: string;
  readonly phase?: string;
  readonly rev?: string;
  readonly subject?: string;
  readonly breached?: readonly string[];
  readonly report?: string;
}

export interface DeployState {
  /** A switch is under way. */
  readonly running: boolean;
  /** The last report is old and not final: the switch may have died. */
  readonly stale: boolean;
  /** The latest switch's reports. */
  readonly run: readonly Report[];
  readonly last?: Report;
  readonly generation?: Generation;
  readonly revert?: Revert;
  /** The GitHub repository the switch applies, for links to its commits. */
  readonly repository?: string;
}

const STALE = 60 * 60_000;
const DAY = 24 * 60 * 60_000;

/** nixos-switch-main's `status.jsonl` reports, `generations.jsonl` outcomes, and `reverts.jsonl`. */
export function deployState(
  reports: readonly Report[],
  generations: readonly Generation[],
  reverts: readonly Revert[],
  now: number,
): DeployState {
  const last = reports.at(-1);
  const runID = last?.run;
  let run: readonly Report[] = [];
  if (runID !== undefined) {
    run = reports.filter((report) => report.run === runID);
  } else if (last) {
    // Reports from before runs had ids: the latest run starts after the last final report.
    let start = reports.length - 1;
    while (
      start > 0 &&
      !(
        reports[start - 1]!.id === "switch" &&
        reports[start - 1]!.state !== "working"
      )
    )
      start--;
    run = reports.slice(start);
  }
  const final =
    last !== undefined &&
    ((last.id === "switch" && last.state !== "working") ||
      last.state === "failed");
  const age = now - (time(last?.time) ?? now);
  return {
    running:
      last !== undefined && !final && last.state !== "blocked" && age < STALE,
    stale: last !== undefined && !final && age >= STALE,
    run,
    last,
    generation: generations.at(-1),
    revert: reverts.at(-1),
  };
}

/** A revert is the host's latest outcome until a later switch records a generation. */
function revertTone(state: DeployState, now: number): Tone {
  const at = time(state.revert?.at);
  if (at === undefined) return "idle";
  if (at > (time(state.generation?.at) ?? 0)) return "error";
  return now - at < DAY ? "warn" : "idle";
}

function outcomeTone(outcome: string | undefined): Tone {
  if (
    outcome === "deployed" ||
    outcome === "unchanged" ||
    outcome === "committed"
  )
    return "ok";
  if (outcome === undefined) return "idle";
  return /revert|reject|fail/i.test(outcome) ? "error" : "warn";
}

function lastTone(state: DeployState): Tone {
  if (state.running) return "busy";
  if (state.stale || state.last?.state === "blocked") return "warn";
  return state.last?.state === "failed" ? "error" : "ok";
}

export function deployRows(state: DeployState, now: number): Row[] {
  const rows: Row[] = [];
  const last = state.last;
  if (last) {
    const ago =
      time(last.time) !== undefined
        ? `${duration(now - time(last.time)!)} ago`
        : undefined;
    rows.push({
      key: "deploy:switch",
      tone: lastTone(state),
      label: state.running
        ? `switching: ${describeReport(last)}`
        : `last switch: ${last.msg ?? last.state}`,
      detail: [state.stale ? "no final report" : undefined, ago]
        .filter(Boolean)
        .join(" · "),
      lines: state.run.map(
        (report) =>
          `${report.time ? `${new Date(report.time).toLocaleTimeString()} ` : ""}${describeReport(report)}`,
      ),
    });
  }
  const generation = state.generation;
  if (generation) {
    rows.push({
      key: "deploy:generation",
      tone: outcomeTone(generation.outcome),
      label: `${generation.host ?? "host"} generation ${generation.generation ?? "?"} · ${generation.outcome ?? "unknown"}`,
      detail: generation.subject,
      copy: generation.rev,
      url:
        generation.rev && state.repository
          ? `https://github.com/${state.repository}/commit/${generation.rev}`
          : undefined,
      lines: [
        `${generation.host ?? "host"} generation ${generation.generation ?? "?"}: ${generation.outcome ?? "unknown"}`,
        ...(generation.subject ? [generation.subject] : []),
        ...(generation.rev ? [`rev ${generation.rev}`] : []),
        ...(generation.toplevel ? [generation.toplevel] : []),
        ...(generation.at
          ? [`at ${new Date(generation.at).toLocaleString()}`]
          : []),
      ],
    });
  }
  const revert = state.revert;
  if (revert) {
    const at = time(revert.at);
    rows.push({
      key: "deploy:revert",
      tone: revertTone(state, now),
      label: `last revert: ${revert.rev?.slice(0, 8) ?? "?"} in ${revert.phase ?? "?"}`,
      detail: [
        revert.breached?.length ? revert.breached.join(", ") : undefined,
        at !== undefined ? `${duration(now - at)} ago` : undefined,
      ]
        .filter(Boolean)
        .join(" · "),
      copy: revert.report ?? revert.rev,
      url:
        revert.rev && state.repository
          ? `https://github.com/${state.repository}/commit/${revert.rev}`
          : undefined,
      lines: [
        `${revert.host ?? "host"} reverted ${revert.rev ?? "?"} during ${revert.phase ?? "?"}`,
        ...(revert.subject ? [revert.subject] : []),
        ...(revert.breached?.length
          ? [`breached: ${revert.breached.join(", ")}`]
          : []),
        ...(at !== undefined ? [`at ${new Date(at).toLocaleString()}`] : []),
        ...(revert.report ? [`report ${revert.report}`] : []),
        "Read the report and deploy-reverts before retrying this revision.",
      ],
    });
  }
  return rows;
}

export function summarizeDeploy(state: DeployState, now: number): Summary {
  const last = state.last;
  if (state.running && last)
    return { tone: "busy", text: `switching · ${describeReport(last)}` };
  const reverted = revertTone(state, now) === "error";
  const generation = state.generation;
  const tone = worst([
    lastTone(state),
    outcomeTone(generation?.outcome),
    revertTone(state, now),
  ]);
  const when = reverted
    ? time(state.revert?.at)
    : (time(last?.time) ?? time(generation?.at));
  return {
    tone,
    text: [
      reverted
        ? `reverted ${state.revert?.rev?.slice(0, 8) ?? ""}`.trim()
        : undefined,
      !reverted && generation
        ? `gen ${generation.generation ?? "?"} ${generation.outcome ?? ""}`.trim()
        : undefined,
      state.stale
        ? "stalled"
        : last?.state === "failed"
          ? "last switch failed"
          : undefined,
      when !== undefined ? `${duration(now - when)} ago` : undefined,
    ]
      .filter(Boolean)
      .join(" · "),
  };
}
