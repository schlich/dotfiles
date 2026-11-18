// Collectors for the workflow-status plugin. Each source of state is read from
// the program or file it lives in, on a schedule that tightens while something
// is in flight, and again on the file-system events that signal a change. A
// hub starts its collectors when the first view needs it and stops them
// shortly after the last view goes.
import { watch } from "node:fs";
import { open, readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { createSignal, type Accessor } from "solid-js";
import * as M from "./model";
import tools, { switchRepository } from "./tools";

// Read-only probes: no index lock, prompts, pagers, or color.
const ENV: Readonly<Record<string, string>> = {
  GIT_OPTIONAL_LOCKS: "0",
  GIT_TERMINAL_PROMPT: "0",
  GH_PROMPT_DISABLED: "1",
  GH_NO_UPDATE_NOTIFIER: "1",
  NO_COLOR: "1",
  PAGER: "cat",
  JJ_EDITOR: "true",
};

export interface Result {
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
}

export async function run(
  command: string,
  args: readonly string[],
  options: { readonly cwd?: string; readonly timeout?: number } = {},
): Promise<Result> {
  let child: ReturnType<typeof Bun.spawn>;
  try {
    child = Bun.spawn([command, ...args], {
      cwd: options.cwd,
      env: { ...process.env, ...ENV },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
  } catch (error) {
    // A missing program or working directory.
    return { code: 127, stdout: "", stderr: message(error) };
  }
  const timer = setTimeout(() => child.kill(), options.timeout ?? 20_000);
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout as ReadableStream<Uint8Array>).text(),
      new Response(child.stderr as ReadableStream<Uint8Array>).text(),
      child.exited,
    ]);
    return { code, stdout, stderr };
  } finally {
    clearTimeout(timer);
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function firstLine(output: string, fallback: string): string {
  return (
    output
      .split("\n")
      .map((line) => line.trim())
      .find(Boolean) ?? fallback
  );
}

function parseJson(output: string): unknown {
  try {
    return JSON.parse(output);
  } catch {
    return undefined;
  }
}

async function readText(file: string): Promise<string | undefined> {
  try {
    return await readFile(file, "utf8");
  } catch {
    return undefined;
  }
}

/** The last `bytes` of a file, from its first complete line. */
async function readTail(
  file: string,
  bytes: number,
): Promise<string | undefined> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(file, "r");
    const { size } = await handle.stat();
    const start = Math.max(0, size - bytes);
    const buffer = Buffer.alloc(size - start);
    await handle.read(buffer, 0, buffer.length, start);
    const content = buffer.toString("utf8");
    return start > 0 ? content.slice(content.indexOf("\n") + 1) : content;
  } catch {
    return undefined;
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as { code?: string }).code === "EPERM";
  }
}

function watchPath(target: string, onChange: () => void): () => void {
  try {
    const watcher = watch(target, { persistent: false }, () => onChange());
    watcher.on("error", () => watcher.close());
    return () => watcher.close();
  } catch {
    return () => undefined;
  }
}

async function lines(
  stream: ReadableStream<Uint8Array>,
  handle: (line: string) => void,
): Promise<void> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      for (
        let index = buffer.indexOf("\n");
        index >= 0;
        index = buffer.indexOf("\n")
      ) {
        handle(buffer.slice(0, index));
        buffer = buffer.slice(index + 1);
      }
    }
  } catch {
    // The follower was killed.
  } finally {
    reader.releaseLock();
  }
}

export interface Section<T> {
  readonly data?: T;
  readonly error?: string;
  /** When data last arrived. */
  readonly updated?: number;
  readonly loading: boolean;
}

export interface Notice {
  readonly variant: "error" | "warning" | "success" | "info";
  readonly title: string;
  readonly message: string;
}

export type Notify = (notice: Notice) => void;

interface Poller {
  /** Runs the task after `delay`, unless a run is already due sooner. */
  readonly poke: (delay?: number) => void;
  readonly stop: () => void;
}

/** Runs `task` one at a time; it returns the delay before its next run. */
function poller(task: () => Promise<number>): Poller {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let due = Number.POSITIVE_INFINITY;
  let busy = false;
  let again = false;
  let stopped = false;
  const schedule = (delay: number) => {
    if (stopped) return;
    const at = Date.now() + delay;
    if (timer !== undefined && due <= at) return;
    clearTimeout(timer);
    due = at;
    timer = setTimeout(() => void tick(), delay);
  };
  const tick = async () => {
    timer = undefined;
    due = Number.POSITIVE_INFINITY;
    if (stopped) return;
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    let next = 60_000;
    try {
      next = await task();
    } catch {
      next = 60_000;
    } finally {
      busy = false;
    }
    if (again) {
      again = false;
      schedule(0);
    } else {
      schedule(next);
    }
  };
  return {
    poke: (delay = 0) => schedule(delay),
    stop: () => {
      stopped = true;
      clearTimeout(timer);
    },
  };
}

// ---- Repository: version control, CI, and luvus tasks ----------------------

interface Repository {
  readonly kind: "jj" | "git" | "none";
  readonly root: string;
  readonly gitDir?: string;
  readonly commonDir?: string;
  readonly colocated: boolean;
  /** The checkout luvus files this repository's tasks under. */
  readonly project: string;
  readonly slug?: string;
  readonly ci: boolean;
  /** Directories whose changes mean the repository moved. */
  readonly watch: readonly string[];
}

/** The directory every JJ operation rewrites: the repository's operation heads. */
async function jjOperations(root: string): Promise<string> {
  // A secondary workspace's .jj/repo is a file naming the repository directory.
  const pointer = path.join(root, ".jj", "repo");
  const target = await readText(pointer);
  const repo =
    target === undefined
      ? pointer
      : path.resolve(path.join(root, ".jj"), target.trim());
  return path.join(repo, "op_heads", "heads");
}

async function inspect(directory: string): Promise<Repository> {
  const [jj, git] = await Promise.all([
    run(tools.jj, ["root", "--ignore-working-copy"], {
      cwd: directory,
      timeout: 5_000,
    }),
    run(
      tools.git,
      [
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
        "--git-dir",
        "--git-common-dir",
      ],
      {
        cwd: directory,
        timeout: 5_000,
      },
    ),
  ]);
  const jjRoot = jj.code === 0 ? jj.stdout.trim() || undefined : undefined;
  const [gitTop, gitDir, commonDir] =
    git.code === 0 ? git.stdout.trim().split("\n") : [];
  // A linked Git worktree inside a JJ checkout is not a JJ workspace: jj would
  // describe the checkout around it.
  const nested =
    jjRoot !== undefined &&
    gitTop !== undefined &&
    gitTop !== jjRoot &&
    gitTop.startsWith(jjRoot + path.sep);
  const kind =
    jjRoot !== undefined && !nested
      ? "jj"
      : gitTop !== undefined
        ? "git"
        : "none";
  const root = kind === "jj" ? jjRoot! : kind === "git" ? gitTop! : directory;
  // In a JJ workspace that is not colocated, Git's view belongs to another checkout.
  const colocated = kind === "jj" && gitTop === jjRoot;
  const useGit = kind === "git" || colocated;
  const [remotes, ci, operations] = await Promise.all([
    gitTop !== undefined
      ? run(tools.git, ["config", "--get-regexp", "^remote\\..*\\.url$"], {
          cwd: root,
          timeout: 5_000,
        })
      : kind === "jj"
        ? run(tools.jj, ["git", "remote", "list", "--ignore-working-copy"], {
            cwd: root,
            timeout: 5_000,
          })
        : undefined,
    kind === "jj"
      ? run(tools.jj, ["config", "get", "ci.enable", "--ignore-working-copy"], {
          cwd: root,
          timeout: 5_000,
        })
      : undefined,
    kind === "jj" ? jjOperations(root) : undefined,
  ]);
  return {
    kind,
    root,
    gitDir: useGit ? gitDir : undefined,
    commonDir: useGit ? commonDir : undefined,
    colocated,
    project: commonDir !== undefined ? M.projectRoot(commonDir) : root,
    slug:
      remotes?.code === 0
        ? M.githubRepository(M.parseRemotes(remotes.stdout))
        : undefined,
    ci: ci?.stdout.trim() === "true",
    watch: [
      useGit ? gitDir : undefined,
      useGit && commonDir !== gitDir ? commonDir : undefined,
      operations,
    ].filter((target): target is string => target !== undefined),
  };
}

async function readVcs(repository: Repository): Promise<M.VcsData> {
  const { root } = repository;
  if (repository.kind === "jj") {
    const [log, status] = await Promise.all([
      // Never snapshot: a status view must not write operations of its own.
      run(
        tools.jj,
        [
          "log",
          "--ignore-working-copy",
          "--no-graph",
          "--color",
          "never",
          "--limit",
          String(M.JJ_LIMIT),
          "-r",
          M.JJ_REVSET,
          "-T",
          M.JJ_TEMPLATE,
        ],
        { cwd: root },
      ),
      repository.colocated
        ? run(tools.git, ["status", "--porcelain=v2", "--branch"], {
            cwd: root,
          })
        : Promise.resolve(undefined),
    ]);
    if (log.code !== 0) throw new Error(firstLine(log.stderr, "jj log failed"));
    const jj = M.parseJjLog(log.stdout);
    if (!jj) throw new Error("jj log listed no working-copy commit");
    const git =
      status?.code === 0 ? M.parseGitStatus(status.stdout) : undefined;
    return {
      kind: "jj",
      root,
      jj,
      git,
      colocated: repository.colocated,
      ci: repository.ci,
    };
  }
  if (repository.kind === "git") {
    const status = await run(
      tools.git,
      ["status", "--porcelain=v2", "--branch"],
      { cwd: root },
    );
    if (status.code !== 0)
      throw new Error(firstLine(status.stderr, "git status failed"));
    const git = M.parseGitStatus(status.stdout);
    const upstream =
      git.upstream !== undefined && git.ahead > 0
        ? await run(
            tools.git,
            ["rev-parse", "--verify", "--quiet", "@{upstream}"],
            { cwd: root },
          )
        : undefined;
    return {
      kind: "git",
      root,
      git,
      upstreamOid: upstream?.code === 0 ? upstream.stdout.trim() : undefined,
      worktree: repository.gitDir !== repository.commonDir,
    };
  }
  return { kind: "none", root };
}

function vcsSignature(data: M.VcsData): string {
  return JSON.stringify([
    data.git?.oid,
    data.git?.branch,
    data.git?.upstream,
    data.git?.ahead,
    data.upstreamOid,
    data.jj?.change.commitId,
    data.jj?.bookmarks,
  ]);
}

/** The pushed commit whose checks describe this checkout, and what to call it. */
async function ciTarget(
  repository: Repository,
  data: M.VcsData,
): Promise<{ readonly sha?: string; readonly label: string }> {
  if (data.kind === "git" && data.git?.oid) {
    const git = data.git;
    if (git.ahead > 0 && data.upstreamOid)
      return {
        sha: data.upstreamOid,
        label: `${git.upstream} (HEAD ${git.ahead} ahead)`,
      };
    return { sha: git.oid, label: git.branch ?? "HEAD" };
  }
  if (data.kind === "jj") {
    const pushed = await run(
      tools.jj,
      [
        "log",
        "--ignore-working-copy",
        "--no-graph",
        "--color",
        "never",
        "--limit",
        "20",
        "-r",
        M.JJ_PUSHED_REVSET,
        "-T",
        M.JJ_PUSHED_TEMPLATE,
      ],
      { cwd: repository.root },
    );
    const found =
      pushed.code === 0 ? M.parseJjPushed(pushed.stdout) : undefined;
    return found
      ? { sha: found.commit, label: found.refs.join(", ") }
      : { label: "nothing pushed yet" };
  }
  return { label: "no commits" };
}

export interface RepoHub {
  readonly vcs: Accessor<Section<M.VcsData>>;
  readonly ci: Accessor<Section<M.CiView>>;
  readonly tasks: Accessor<Section<M.TaskView>>;
  readonly refresh: (section?: "vcs" | "ci" | "tasks") => void;
  readonly dispose: () => void;
}

function createRepoHub(directory: string, notify: Notify): RepoHub {
  const [vcs, setVcs] = createSignal<Section<M.VcsData>>({ loading: true });
  const [ci, setCi] = createSignal<Section<M.CiView>>({ loading: true });
  const [tasks, setTasks] = createSignal<Section<M.TaskView>>({
    loading: true,
  });
  const unwatch: Array<() => void> = [];
  let disposed = false;

  const ready = inspect(directory).then((repository) => {
    if (!disposed)
      for (const target of repository.watch)
        unwatch.push(watchPath(target, () => vcsPoller.poke(300)));
    return repository;
  });

  let signature = "";
  const vcsPoller = poller(async () => {
    const repository = await ready;
    try {
      const data = await readVcs(repository);
      setVcs({ data, loading: false, updated: Date.now() });
      const next = vcsSignature(data);
      if (next !== signature) {
        // A new commit or branch: its checks and task may differ.
        signature = next;
        ciPoller.poke(0);
        taskPoller.poke(0);
      }
    } catch (error) {
      setVcs((previous) => ({
        ...previous,
        loading: false,
        error: message(error),
      }));
    }
    return repository.kind === "none" ? 300_000 : 6_000;
  });

  let pulls: readonly M.PullRequest[] = [];
  let pullsFor = "";
  let pullsAt = 0;
  let lastTone: M.Tone | undefined;
  let lastGate: M.CheckState | undefined;
  const ciPoller = poller(async () => {
    const repository = await ready;
    const data = vcs().data;
    if (!data) return 2_000;
    const done = (view: M.CiView) =>
      setCi({ data: view, loading: false, updated: Date.now() });
    if (!repository.slug) {
      done({
        target:
          repository.kind === "none" ? "no repository" : "no GitHub remote",
        checks: [],
        pulls: [],
      });
      return 600_000;
    }
    const target = await ciTarget(repository, data);
    if (!target.sha) {
      done({
        slug: repository.slug,
        target: target.label,
        checks: [],
        pulls: [],
      });
      return 60_000;
    }
    const base = `repos/${repository.slug}/commits/${target.sha}`;
    const [runs, statuses] = await Promise.all([
      run(tools.gh, ["api", `${base}/check-runs?per_page=100`]),
      run(tools.gh, ["api", `${base}/status`]),
    ]);
    if (runs.code !== 0) {
      // GitHub has never seen a commit that was only pushed elsewhere.
      if (/No commit found|HTTP 422/i.test(runs.stderr)) {
        done({
          slug: repository.slug,
          sha: target.sha,
          target: `${target.label} (not on GitHub)`,
          checks: [],
          pulls: [],
        });
        return 120_000;
      }
      setCi((previous) => ({
        ...previous,
        loading: false,
        error: `gh: ${firstLine(runs.stderr, "request failed")}`,
      }));
      return /rate limit/i.test(runs.stderr) ? 600_000 : 120_000;
    }
    const checks = [
      ...M.parseCheckRuns(parseJson(runs.stdout)),
      ...(statuses.code === 0
        ? M.parseStatuses(parseJson(statuses.stdout))
        : []),
    ];
    if (pullsFor !== target.sha || Date.now() - pullsAt > 300_000) {
      const result = await run(tools.gh, ["api", `${base}/pulls`]);
      if (result.code === 0) pulls = M.parsePulls(parseJson(result.stdout));
      pullsFor = target.sha;
      pullsAt = Date.now();
    }
    const tone = M.summarizeChecks(checks).tone;
    const gate = M.gateState(checks);
    const where = `${repository.slug} · ${target.label}`;
    if (lastTone !== undefined && lastTone !== "error" && tone === "error")
      notify({
        variant: "error",
        title: "CI failed",
        message: `${where}: ${M.failingNames(checks)}`,
      });
    else if (lastGate === "running" && gate === "passed")
      notify({ variant: "success", title: "nixbot passed", message: where });
    lastTone = tone;
    lastGate = gate;
    done({
      slug: repository.slug,
      sha: target.sha,
      target: target.label,
      checks,
      pulls,
    });
    return checks.some((check) => check.state === "running") ? 20_000 : 120_000;
  });

  let statuses = new Map<string, string>();
  let tasksLoaded = false;
  const taskPoller = poller(async () => {
    const repository = await ready;
    if (repository.kind === "none") {
      setTasks({ loading: false });
      return 600_000;
    }
    const result = await run(tools.luvus, ["task", "list", "--json"], {
      timeout: 8_000,
    });
    if (result.code === 127) {
      // luvus is not installed: no Tasks section.
      setTasks({ loading: false });
      return 600_000;
    }
    if (result.code !== 0) {
      setTasks((previous) => ({
        ...previous,
        loading: false,
        error: `luvus: ${firstLine(result.stderr || result.stdout, "task list failed")}`,
      }));
      return 30_000;
    }
    const list = M.projectTasks(
      M.parseTasks(parseJson(result.stdout)),
      repository.project,
    );
    const current = M.currentTask(list, {
      root: repository.root,
      branch: vcs().data?.git?.branch,
    });
    if (tasksLoaded)
      for (const task of list) {
        const before = statuses.get(task.id);
        if (before === undefined || before === task.status) continue;
        if (task.status === "blocked")
          notify({
            variant: "warning",
            title: `Task ${task.id} blocked`,
            message: task.notes.at(-1) ?? task.title,
          });
        else if (task.status === "review")
          notify({
            variant: "info",
            title: `Task ${task.id} needs review`,
            message: task.title,
          });
      }
    statuses = new Map(list.map((task) => [task.id, task.status]));
    tasksLoaded = true;
    setTasks({
      data: { tasks: list, current },
      loading: false,
      updated: Date.now(),
    });
    return 10_000;
  });

  vcsPoller.poke(0);
  taskPoller.poke(0);

  return {
    vcs,
    ci,
    tasks,
    refresh(section) {
      if (section === undefined || section === "vcs") vcsPoller.poke(0);
      if (section === undefined || section === "ci") ciPoller.poke(0);
      if (section === undefined || section === "tasks") taskPoller.poke(0);
    },
    dispose() {
      disposed = true;
      vcsPoller.stop();
      ciPoller.stop();
      taskPoller.stop();
      for (const close of unwatch.splice(0)) close();
    },
  };
}

// ---- Host: background jobs and the staged NixOS switch ----------------------

const SWITCH = "/var/lib/nixos-switch-main";

export interface HostHub {
  /** `job-log` and ci MCP jobs, from cross.stream. */
  readonly jobs: Accessor<Section<readonly M.Job[]>>;
  /** Claude Code's background tasks, from the Fieldnotes records. */
  readonly claude: Accessor<Section<readonly M.Job[]>>;
  readonly deploy: Accessor<Section<M.DeployState>>;
  readonly refresh: (section?: "jobs" | "deploy") => void;
  readonly dispose: () => void;
}

function parseFrame(line: string): M.Frame | undefined {
  if (!line.trim()) return undefined;
  const value = parseJson(line) as Partial<M.Frame> | undefined;
  return value &&
    typeof value.topic === "string" &&
    typeof value.id === "string"
    ? (value as M.Frame)
    : undefined;
}

/** What a job runs: `LOG.job.nuon`'s task, or the arguments a ci MCP job recorded. */
async function jobLabel(log: string): Promise<string | undefined> {
  const record = await readText(`${log}.job.nuon`);
  const task = record === undefined ? undefined : M.nuonField(record, "task");
  if (task) return task;
  if (path.basename(log) !== "log") return undefined;
  const meta = parseJson(
    (await readText(path.join(path.dirname(log), "meta.json"))) ?? "",
  ) as { args?: unknown } | undefined;
  return Array.isArray(meta?.args)
    ? ["ci", ...meta.args.map(String)].join(" ")
    : undefined;
}

/** A job's result file, for a job whose done frame never reached the store. */
async function jobResult(
  log: string,
): Promise<{ exit_code?: number; error?: string } | undefined> {
  const done = await readText(`${log}.done.nuon`);
  if (done !== undefined) {
    const exit = Number(M.nuonField(done, "exit_code"));
    return Number.isFinite(exit)
      ? { exit_code: exit, error: M.nuonField(done, "error") }
      : undefined;
  }
  if (path.basename(log) !== "log") return undefined;
  const exit = Number(
    (await readText(path.join(path.dirname(log), "exit")))?.trim(),
  );
  return Number.isFinite(exit) ? { exit_code: exit } : undefined;
}

function createHostHub(notify: Notify): HostHub {
  const [jobs, setJobs] = createSignal<Section<readonly M.Job[]>>({
    loading: true,
  });
  const [claude, setClaude] = createSignal<Section<readonly M.Job[]>>({
    loading: true,
  });
  const [deploy, setDeploy] = createSignal<Section<M.DeployState>>({
    loading: true,
  });
  const known = new Map<string, M.Job>();
  const labelled = new Set<string>();
  // Jobs this hub saw running with a live owner: only their ends are news. A
  // backfilled job whose owner died long ago ended when it started, as far as
  // this view can tell.
  const seenAlive = new Set<string>();
  const cleanups: Array<() => void> = [];
  let stopped = false;
  let follower: ReturnType<typeof Bun.spawn> | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;

  const publish = () =>
    setJobs({ data: [...known.values()], loading: false, updated: Date.now() });

  const failed = (job: M.Job) =>
    notify({
      variant: "error",
      title: `Job ${job.state === "lost" ? "lost" : "failed"}: ${job.label.slice(0, 60)}`,
      message: [
        job.state === "lost"
          ? "its owner exited without a result"
          : `exit ${job.exit ?? "?"}`,
        job.cwd ? M.basename(job.cwd) : undefined,
        job.error,
      ]
        .filter(Boolean)
        .join(" · "),
    });

  // Forget jobs long finished, so a long session does not accumulate them.
  const prune = () => {
    const horizon = Date.now() - 2 * M.RECENT;
    for (const [id, job] of known)
      if (
        job.state !== "running" &&
        (job.finished ?? job.started ?? 0) < horizon
      ) {
        known.delete(id);
        labelled.delete(id);
        seenAlive.delete(id);
      }
  };

  // When a job this hub never saw alive ended, for all it knows.
  const endedAt = (job: M.Job) =>
    seenAlive.has(job.id) ? Date.now() : (job.started ?? Date.now());

  // Name new jobs, follow running ones' progress reports, and notice a job
  // whose owner died without a result or whose done frame never arrived.
  const enrichPoller = poller(async () => {
    let live = false;
    for (const job of [...known.values()]) {
      let next = job;
      if (next.log && !labelled.has(next.id)) {
        labelled.add(next.id);
        const label = await jobLabel(next.log);
        if (label) next = { ...next, label };
      }
      if (next.state === "running") {
        const result = next.log ? await jobResult(next.log) : undefined;
        if (result) {
          next = M.finishJob(next, result, endedAt(next));
          if (next.state === "failed" && seenAlive.has(next.id)) failed(next);
        } else {
          const tail = next.log
            ? await readTail(`${next.log}.status.jsonl`, 16_384)
            : undefined;
          if (tail !== undefined)
            next = {
              ...next,
              phase: M.latestPhase(M.parseJsonLines<M.Report>(tail)),
            };
          // A ci MCP job's unit outlives the server that started it; its result file ends it.
          const owner =
            next.pid !== undefined && next.unit === undefined
              ? alive(next.pid)
              : undefined;
          const ancient =
            next.started !== undefined &&
            Date.now() - next.started > 24 * 60 * 60_000;
          if (owner === true && !ancient) seenAlive.add(next.id);
          else if (owner === false || ancient) {
            const observed = seenAlive.has(next.id);
            next = { ...next, state: "lost", finished: endedAt(next) };
            if (observed) failed(next);
          }
        }
      }
      if (next.state === "running") live = true;
      if (next !== job) known.set(job.id, next);
    }
    prune();
    publish();
    return live ? 3_000 : 30_000;
  });

  const store =
    process.env.XS_ADDR ??
    path.join(homedir(), ".local", "share", "cross.stream", "store");
  let backoff = 5_000;
  const retry = () => {
    if (stopped) return;
    clearTimeout(retryTimer);
    retryTimer = setTimeout(() => void follow(), backoff);
    backoff = Math.min(backoff * 2, 120_000);
  };
  // Backfill recent job frames, then follow new ones from the last seen.
  const follow = async (): Promise<void> => {
    if (stopped) return;
    const backfill = await run(
      tools.xs,
      ["cat", store, "--topic", "job.*", "--last", "400", "--with-timestamp"],
      { timeout: 15_000 },
    );
    if (stopped) return;
    if (backfill.code !== 0) {
      setJobs((previous) => ({
        ...previous,
        loading: false,
        error: `cross.stream: ${firstLine(backfill.stderr, "unavailable")}`,
      }));
      return retry();
    }
    let after: string | undefined;
    for (const line of backfill.stdout.split("\n")) {
      const frame = parseFrame(line);
      if (!frame) continue;
      M.applyFrame(known, frame);
      after = frame.id;
    }
    publish();
    enrichPoller.poke(0);
    try {
      follower = Bun.spawn(
        [
          tools.xs,
          "cat",
          store,
          "--topic",
          "job.*",
          "--follow",
          "--with-timestamp",
          ...(after ? ["--after", after] : ["--new"]),
        ],
        {
          env: { ...process.env, ...ENV },
          stdin: "ignore",
          stdout: "pipe",
          stderr: "ignore",
        },
      );
    } catch (error) {
      setJobs((previous) => ({
        ...previous,
        loading: false,
        error: `cross.stream: ${message(error)}`,
      }));
      return retry();
    }
    backoff = 5_000;
    await lines(follower.stdout as ReadableStream<Uint8Array>, (line) => {
      const frame = parseFrame(line);
      const job = frame ? M.applyFrame(known, frame) : undefined;
      if (!job) return;
      // A job that starts while this hub follows the store is news when it ends.
      if (job.state === "running") seenAlive.add(job.id);
      if (job.state === "failed") failed(job);
      publish();
      enrichPoller.poke(job.state === "running" ? 200 : 0);
    });
    follower = undefined;
    retry();
  };

  const tasksDirectory = path.join(
    process.env.XDG_STATE_HOME ?? path.join(homedir(), ".local", "state"),
    "fieldnotes",
    "agent-tasks",
  );
  const claudePoller = poller(async () => {
    const names = await readdir(tasksDirectory).catch(() => undefined);
    if (names === undefined) {
      setClaude({ data: [], loading: false, updated: Date.now() });
      return 60_000;
    }
    const records = await Promise.all(
      names
        .filter((name) => name.endsWith(".json"))
        .map(async (name) =>
          parseJson((await readText(path.join(tasksDirectory, name))) ?? ""),
        ),
    );
    setClaude({
      data: M.claudeJobs(records),
      loading: false,
      updated: Date.now(),
    });
    return 5_000;
  });

  let lastDeploy: M.DeployState | undefined;
  const deployPoller = poller(async () => {
    const [status, generations, reverts] = await Promise.all([
      readTail(path.join(SWITCH, "status.jsonl"), 65_536),
      readTail(path.join(SWITCH, "generations.jsonl"), 16_384),
      readTail(path.join(SWITCH, "reverts.jsonl"), 16_384),
    ]);
    if (status === undefined && generations === undefined) {
      // Not a host that switches through nixos-switch-main.
      setDeploy({ loading: false });
      return 600_000;
    }
    const state: M.DeployState = {
      ...M.deployState(
        M.parseJsonLines<M.Report>(status ?? ""),
        M.parseJsonLines<M.Generation>(generations ?? ""),
        M.parseJsonLines<M.Revert>(reverts ?? ""),
        Date.now(),
      ),
      repository: switchRepository,
    };
    if (lastDeploy !== undefined) {
      if (
        state.revert?.id !== undefined &&
        state.revert.id !== lastDeploy.revert?.id
      )
        notify({
          variant: "error",
          title: `Switch reverted on ${state.revert.host ?? "this host"}`,
          message: `${state.revert.subject ?? state.revert.rev ?? ""} · ${state.revert.breached?.join(", ") ?? state.revert.phase ?? ""}`,
        });
      else if (lastDeploy.running && !state.running && state.last)
        notify({
          variant: state.last.state === "failed" ? "error" : "success",
          title:
            state.last.state === "failed" ? "Switch failed" : "Switch finished",
          message: state.last.msg ?? state.last.state ?? "",
        });
    }
    lastDeploy = state;
    setDeploy({ data: state, loading: false, updated: Date.now() });
    return state.running ? 3_000 : 15_000;
  });

  cleanups.push(watchPath(tasksDirectory, () => claudePoller.poke(200)));
  cleanups.push(watchPath(SWITCH, () => deployPoller.poke(200)));
  void follow();
  claudePoller.poke(0);
  deployPoller.poke(0);

  return {
    jobs,
    claude,
    deploy,
    refresh(section) {
      if (section === undefined || section === "jobs") {
        enrichPoller.poke(0);
        claudePoller.poke(0);
      }
      if (section === undefined || section === "deploy") deployPoller.poke(0);
    },
    dispose() {
      stopped = true;
      clearTimeout(retryTimer);
      follower?.kill();
      enrichPoller.stop();
      claudePoller.stop();
      deployPoller.stop();
      for (const close of cleanups.splice(0)) close();
    },
  };
}

// ---- Hubs ------------------------------------------------------------------

export interface Lease<T> {
  readonly hub: T;
  readonly release: () => void;
}

export interface Hubs {
  readonly repo: (directory: string) => Lease<RepoHub>;
  readonly host: () => Lease<HostHub>;
  /** OpenCode finished something that may have moved the repositories in view. */
  readonly activity: () => void;
  readonly dispose: () => void;
}

// A hub outlives its last view this long, so switching sessions does not restart it.
const LINGER = 30_000;

interface Entry<T> {
  readonly hub: T;
  refs: number;
  timer?: ReturnType<typeof setTimeout>;
}

export function createHubs(notify: Notify): Hubs {
  const repos = new Map<string, Entry<RepoHub>>();
  let host: Entry<HostHub> | undefined;

  const lease = <T extends { dispose: () => void }>(
    entry: Entry<T>,
    drop: () => void,
  ): Lease<T> => {
    entry.refs++;
    clearTimeout(entry.timer);
    entry.timer = undefined;
    let released = false;
    return {
      hub: entry.hub,
      release: () => {
        if (released) return;
        released = true;
        entry.refs--;
        if (entry.refs === 0)
          entry.timer = setTimeout(() => {
            if (entry.refs > 0) return;
            entry.hub.dispose();
            drop();
          }, LINGER);
      },
    };
  };

  return {
    repo(directory) {
      let entry = repos.get(directory);
      if (!entry) {
        entry = { hub: createRepoHub(directory, notify), refs: 0 };
        repos.set(directory, entry);
      }
      const current = entry;
      return lease(current, () => {
        if (repos.get(directory) === current) repos.delete(directory);
      });
    },
    host() {
      if (!host) host = { hub: createHostHub(notify), refs: 0 };
      const current = host;
      return lease(current, () => {
        if (host === current) host = undefined;
      });
    },
    activity() {
      for (const entry of repos.values()) entry.hub.refresh("vcs");
    },
    dispose() {
      for (const entry of repos.values()) {
        clearTimeout(entry.timer);
        entry.hub.dispose();
      }
      repos.clear();
      if (host) {
        clearTimeout(host.timer);
        host.hub.dispose();
        host = undefined;
      }
    },
  };
}

// ---- Actions ---------------------------------------------------------------

/** Opens a URL in the desktop's browser; over SSH there is none, and the caller copies it instead. */
export function openUrl(url: string): boolean {
  if (!process.env.WAYLAND_DISPLAY && !process.env.DISPLAY) return false;
  try {
    Bun.spawn([tools.xdgOpen, url], {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
    }).unref();
    return true;
  } catch {
    return false;
  }
}

/** Copies through OpenTUI's clipboard (the host's, and OSC 52 to the terminal), or else wl-copy. */
export async function copyText(
  renderer: unknown,
  value: string,
): Promise<boolean> {
  try {
    const core = (await import("@opentui/core")) as Record<string, any>;
    const clipboard = core.createClipboard({
      host: core.createHostClipboard(),
      terminal: core.createRendererClipboardAdapter(renderer),
    });
    try {
      const result = await clipboard.writeText(value.replaceAll("\0", ""), {
        destination: "all-available",
        selection: "clipboard",
      });
      if (
        result?.host?.status === "written" ||
        result?.terminal?.status === "attempted"
      )
        return true;
    } finally {
      await clipboard.dispose?.();
    }
  } catch {
    // Fall through to wl-copy.
  }
  if (!process.env.WAYLAND_DISPLAY) return false;
  try {
    const child = Bun.spawn([tools.wlCopy], {
      stdin: new Response(value),
      stdout: "ignore",
      stderr: "ignore",
    });
    return (await child.exited) === 0;
  } catch {
    return false;
  }
}
