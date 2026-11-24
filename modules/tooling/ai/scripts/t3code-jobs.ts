// t3code-jobs: give every job an agent starts its own terminal in the agent's
// T3 Code thread, streaming the job as it runs.
//
// job-log (nu-mcp-config.nu) announces each job's start on this host's
// cross.stream store with its log, directory, and the T3 Code thread whose
// agent started it. For each such start this opens, in that thread, a
// terminal named `job-<log name>` in the job's directory and types
// `job-stream LOG` into it. A rerun of the same log replaces its terminal, so
// a thread's drawer holds one tab per job, finished ones included, and the
// server keeps them across reconnects. Jobs that name no thread are left
// alone. T3 Code has no way to open the drawer for the user; the tabs are
// there whenever it is opened.
//
// It talks to the server's /ws RPC with a bearer token that can only operate
// terminals, issued with `t3 auth session issue` at each start; the unit
// restarts daily, before the token expires. The last frame handled is kept
// in STATE_DIR, so a restart picks up the jobs that started meanwhile, except
// ones over an hour old.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const env = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`t3code-jobs: ${name} is not set`);
  return value;
};
const serverUrl = env("T3CODE_URL");
const t3 = env("T3_BIN");
const xs = env("XS_BIN");
const store = env("XS_STORE");
const jobStream = env("JOB_STREAM");
const stateDir = env("STATE_DIR");
const lastFile = join(stateDir, "last-frame");
const maxAge = 60 * 60 * 1000;

const log = (msg: string) => console.log(`t3code-jobs: ${msg}`);

function issueToken(): string {
  const r = Bun.spawnSync([
    t3,
    "auth",
    "session",
    "issue",
    "--scope",
    "terminal:operate",
    "--scope",
    "terminal:read",
    "--ttl",
    "2d",
    "--label",
    "t3code-jobs",
    "--token-only",
  ]);
  const token = r.stdout.toString().trim();
  if (r.exitCode !== 0 || token === "") {
    throw new Error(
      `t3code-jobs: could not issue a token: ${r.stderr.toString().trim()}`,
    );
  }
  return token;
}

// ── The server's RPC, reconnecting when the server restarts ──────────────

type Exit =
  | { _tag: "Success"; value: unknown }
  | { _tag: "Failure"; cause: unknown };

class Rpc {
  private ws: WebSocket | null = null;
  private ready: Promise<void> | null = null;
  private next = 0;
  private pending = new Map<string, (exit: Exit) => void>();

  constructor(
    private url: string,
    private token: string,
  ) {}

  private connect(): Promise<void> {
    if (this.ready) return this.ready;
    this.ready = new Promise((resolve, reject) => {
      const ws = new WebSocket(`${this.url}/ws?orchestrationProtocol=2`, {
        headers: { Authorization: `Bearer ${this.token}` },
      } as any);
      ws.onopen = () => {
        this.ws = ws;
        resolve();
      };
      ws.onmessage = (e) => {
        const m = JSON.parse(String(e.data));
        if (m._tag === "Ping") ws.send(JSON.stringify({ _tag: "Pong" }));
        else if (m._tag === "Exit") {
          this.pending.get(m.requestId)?.(m.exit);
          this.pending.delete(m.requestId);
        }
      };
      ws.onclose = (e) => {
        this.ws = null;
        this.ready = null;
        for (const settle of this.pending.values())
          settle({ _tag: "Failure", cause: `socket closed (${e.code})` });
        this.pending.clear();
        reject(new Error(`socket closed (${e.code} ${e.reason})`));
      };
    });
    return this.ready;
  }

  async call(tag: string, payload: unknown): Promise<Exit> {
    await this.connect();
    const id = String(this.next++);
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.ws!.send(
        JSON.stringify({ _tag: "Request", id, tag, payload, headers: [] }),
      );
    });
  }
}

// ── Jobs ─────────────────────────────────────────────────────────────────

type Frame = {
  id: string;
  topic: string;
  timestamp?: string;
  meta?: Record<string, any>;
};

// T3 terminal ids are free text; keep them short and plain.
const terminalId = (logPath: string) =>
  `job-${basename(logPath)
    .replace(/[^A-Za-z0-9._-]/g, "-")
    .slice(0, 60)}`;

async function showJob(rpc: Rpc, frame: Frame) {
  const { thread: threadId, log: logPath, cwd } = frame.meta ?? {};
  if (!threadId || !logPath) return;
  if (frame.timestamp && Date.now() - Date.parse(frame.timestamp) > maxAge)
    return;
  const id = terminalId(logPath);
  // A rerun of the same log replaces the old run's terminal.
  await rpc.call("terminal.close", {
    threadId,
    terminalId: id,
    deleteHistory: true,
  });
  const opened = await rpc.call("terminal.open", {
    threadId,
    terminalId: id,
    cwd: cwd ?? process.env.HOME,
    cols: 160,
    rows: 40,
  });
  if (opened._tag !== "Success") {
    log(
      `could not open ${id} in thread ${threadId}: ${JSON.stringify(opened.cause).slice(0, 300)}`,
    );
    return;
  }
  // T3 types a Nushell project script as soon as the shell exists; give the
  // shell a moment, then do the same. The leading space keeps it out of
  // shell history.
  await Bun.sleep(800);
  const wrote = await rpc.call("terminal.write", {
    threadId,
    terminalId: id,
    data: ` ${jobStream} ${JSON.stringify(logPath)}\r`,
  });
  log(
    wrote._tag === "Success"
      ? `streaming ${logPath} in ${id} of thread ${threadId}`
      : `could not write to ${id}`,
  );
}

function lastFrame(): string | null {
  try {
    return readFileSync(lastFile, "utf8").trim() || null;
  } catch {
    return null;
  }
}

async function follow(rpc: Rpc) {
  const after = lastFrame();
  const args = [
    xs,
    "cat",
    "--follow",
    "--with-timestamp",
    "--topic",
    "job.*",
    ...(after ? ["--after", after] : ["--new"]),
    store,
  ];
  const proc = Bun.spawn(args, { stdout: "pipe", stderr: "inherit" });
  log(`following job events in ${store}${after ? ` after ${after}` : ""}`);
  let buffered = "";
  for await (const chunk of proc.stdout as any as AsyncIterable<Uint8Array>) {
    buffered += new TextDecoder().decode(chunk);
    let newline: number;
    while ((newline = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (!line) continue;
      let frame: Frame;
      try {
        frame = JSON.parse(line);
      } catch {
        continue;
      }
      if (frame.topic?.endsWith(".start")) {
        try {
          await showJob(rpc, frame);
        } catch (e) {
          log(`job ${frame.meta?.log}: ${(e as Error).message}`);
        }
      }
      writeFileSync(lastFile, frame.id);
    }
  }
  log(`xs exited (${await proc.exited})`);
}

mkdirSync(stateDir, { recursive: true });
const rpc = new Rpc(serverUrl, issueToken());
for (;;) {
  await follow(rpc).catch((e) => log(`follow: ${(e as Error).message}`));
  await Bun.sleep(5000);
}
