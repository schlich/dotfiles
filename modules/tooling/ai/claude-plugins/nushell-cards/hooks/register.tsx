import { read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { NushellJob } from "../types";

// The Nushell MCP server's evaluate tool, under whichever plugin ships it.
const EVALUATE = /^mcp__.*nushell__evaluate$/;
// Source lines a card shows before folding the rest behind a button.
const FOLDED_LINES = 3;
// Log lines a job's Monitor card shows.
const TAIL_LINES = 5;
// A log at most this size is read whole; a larger one is tailed.
const READ_LIMIT = 1024 * 1024;
const POLL_MS = 1000;
// Stop following a job that has run this long without an outcome.
const FOLLOW_LIMIT_MS = 12 * 60 * 60 * 1000;
// Logs kept in the follow list, oldest dropped first.
const MAX_LOGS = 50;

const jobs = { plugin: "nushell-cards", key: "jobs" } as const;
const logs = { plugin: "nushell-cards", key: "logs" } as const;
const expanded = { plugin: "nushell-cards", key: "expanded" } as const;

type Dollar = EngineInterface;

// The text of a tool result, whichever shape it arrives in: a string, MCP
// content blocks, or a record holding them.
export function resultText(output: unknown): string {
  if (typeof output === "string") return output;
  if (Array.isArray(output)) {
    return output
      .map((block) =>
        block !== null &&
        typeof block === "object" &&
        typeof block.text === "string"
          ? block.text
          : "",
      )
      .join("\n");
  }
  if (output !== null && typeof output === "object") {
    const record = output as { content?: unknown; text?: unknown };
    if (Array.isArray(record.content)) return resultText(record.content);
    if (typeof record.text === "string") return record.text;
  }
  return "";
}

// The log of the `{job, log}` record `job-log` returns, from an evaluate result.
export function jobLog(output: unknown): string | undefined {
  try {
    const reply = JSON.parse(resultText(output));
    const result = reply?.output;
    const isJob =
      result !== null && typeof result === "object" && "job" in result;
    return isJob && typeof result.log === "string" && result.log.startsWith("/")
      ? result.log
      : undefined;
  } catch {
    return undefined;
  }
}

// The card's title is the `# comment` line the call opens with, as the
// global instructions ask every evaluation to start.
export function splitSource(source: string): { title: string; body: string[] } {
  const lines = source.replace(/\s+$/, "").split("\n");
  const first = lines[0]?.trim() ?? "";
  const hasTitle = first.startsWith("#");
  const body = hasTitle ? lines.slice(1) : lines;
  while (body.length > 0 && body[0]?.trim() === "") body.shift();
  return { title: hasTitle ? first.replace(/^#+\s*/, "") : "nushell", body };
}

// The log a `watch-job LOG` Monitor follows: the literal path, or, for a
// path built in Nushell (`$"($S)/build.log"`), the followed log with that
// name, or for a bare variable, the newest followed log.
export function monitoredLog(
  command: unknown,
  known: readonly string[],
): string | undefined {
  if (typeof command !== "string") return undefined;
  const match = command.match(
    /\bwatch-job\s+(?:--?[\w-]+(?:\s+(?!['"$\/~])\S+)?\s+)*(\S+)/,
  );
  if (match?.[1] === undefined) return undefined;
  const token = match[1].replace(/^\$?(["'])(.*)\1$/, "$2");
  if (token.startsWith("/")) return token;
  const name = token.match(/\/([^/()$]+)$/)?.[1];
  const newest = [...known].reverse();
  if (name !== undefined) return newest.find((log) => log.endsWith(`/${name}`));
  return /^\$\w+$/.test(token) ? newest[0] : undefined;
}

// One terminal line as a reader sees it: the last carriage-return overwrite,
// without colours, OSC reports, or other escape sequences.
export function cleanLine(line: string): string {
  return (line.split("\r").pop() ?? "")
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
}

export function lastLines(text: string, count: number): string[] {
  return text
    .split("\n")
    .map(cleanLine)
    .filter((line) => line.trim() !== "")
    .slice(-count);
}

// The latest OSC 7501 report among `pst report`'s JSON lines.
export function latestPhase(text: string): string | undefined {
  const reports = text
    .split("\n")
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return undefined;
      }
    })
    .filter(
      (report) => report?.state !== undefined && report.state !== "clear",
    );
  const last = reports.at(-1);
  if (last === undefined) return undefined;
  return [last.state, last.msg]
    .filter((part) => typeof part === "string" && part !== "")
    .join(" · ");
}

// `LOG.done.nuon`'s `{exit_code, error?}`, read without a NUON parser.
export function parseOutcome(
  text: string,
): { exitCode: number; error?: string } | undefined {
  const code = text.match(/exit_code:\s*(-?\d+)/);
  if (code === null) return undefined;
  const raw = text
    .match(/\berror:\s*("(?:[^"\\]|\\.)*"|'[^']*'|[^,}]+)/)?.[1]
    ?.trim();
  let error: string | undefined;
  if (raw !== undefined) {
    try {
      error = raw.startsWith('"')
        ? JSON.parse(raw)
        : raw.replace(/^'(.*)'$/, "$1");
    } catch {
      error = raw;
    }
  }
  return error === undefined
    ? { exitCode: Number(code[1]) }
    : { exitCode: Number(code[1]), error };
}

async function readText($: Dollar, path: string): Promise<string | undefined> {
  const stat = await $.fs.stat(path).catch(() => undefined);
  if (stat === undefined || stat.kind !== "file") return undefined;
  if (stat.size <= READ_LIMIT) return $.fs.read(path).catch(() => undefined);
  const tail = await $.process
    .run(["tail", "-n", String(TAIL_LINES * 4), path])
    .catch(() => undefined);
  return tail?.stdout;
}

// The pid of the Nushell that runs the job: `job-log`'s `LOG.job.nuon`, or a
// ci MCP job's `meta.json` beside its `log`.
async function ownerPid($: Dollar, log: string): Promise<number | undefined> {
  const record = await readText($, `${log}.job.nuon`);
  const fromRecord = record?.match(/\bpid:\s*(\d+)/)?.[1];
  if (fromRecord !== undefined) return Number(fromRecord);
  if (!log.endsWith("/log")) return undefined;
  const meta = await readText($, `${log.slice(0, -"log".length)}meta.json`);
  try {
    const pid = meta === undefined ? undefined : JSON.parse(meta).pid;
    return typeof pid === "number" ? pid : undefined;
  } catch {
    return undefined;
  }
}

async function readOutcome($: Dollar, log: string) {
  const done = await readText($, `${log}.done.nuon`);
  if (done !== undefined) return parseOutcome(done);
  if (!log.endsWith("/log")) return undefined;
  const exit = await readText($, `${log.slice(0, -"log".length)}exit`);
  const code = exit?.trim();
  return code !== undefined && /^-?\d+$/.test(code)
    ? { exitCode: Number(code) }
    : undefined;
}

// Read one job's files and store what changed. Check the owner before the
// outcome, so a job that finishes in between reads as finished, not lost.
async function poll($: Dollar, log: string, now: number): Promise<void> {
  const ref = { ...jobs, id: log };
  const { value: previous } = await $.state.get(ref);
  const startedAt = previous?.startedAt ?? now;
  const pid = await ownerPid($, log);
  const isAlive = pid === undefined || (await $.fs.exists(`/proc/${pid}`));
  const outcome = await readOutcome($, log);
  const text = await readText($, log);
  const phase = latestPhase((await readText($, `${log}.status.jsonl`)) ?? "");
  const isLost = outcome === undefined && !isAlive;
  const isStale = now - startedAt > FOLLOW_LIMIT_MS;
  const job: NushellJob = {
    log,
    tail: lastLines(text ?? "", TAIL_LINES),
    startedAt,
    isDone: outcome !== undefined || isLost || isStale,
    ...(phase !== undefined && phase !== "" && { phase }),
    ...(outcome !== undefined && { exitCode: outcome.exitCode }),
    ...(outcome?.error !== undefined && { error: outcome.error }),
    ...(isLost && { isLost }),
  };
  if (JSON.stringify(previous) !== JSON.stringify(job))
    await $.state.set(ref, job);
}

async function followLog($: Dollar, log: string): Promise<void> {
  await update($, logs, (list) =>
    [...(list ?? []).filter((one) => one !== log), log].slice(-MAX_LOGS),
  );
}

function glyph(props: {
  isRunning: boolean;
  isErrored: boolean;
  isInterrupted: boolean;
}) {
  if (props.isInterrupted) return { mark: "⏹", color: "warning" };
  if (props.isRunning) return { mark: "…", color: "claude" };
  if (props.isErrored) return { mark: "✗", color: "error" };
  return { mark: "✓", color: "success" };
}

function jobSummary(job: NushellJob): { text: string; color: string } {
  const name = job.log.split("/").pop() ?? job.log;
  if (job.isLost)
    return { text: `${name} · lost: its Nushell exited first`, color: "error" };
  if (job.exitCode !== undefined) {
    const failed = job.exitCode !== 0;
    const error = job.error !== undefined ? ` · ${job.error}` : "";
    return {
      text: `${name} · exit ${job.exitCode}${error}`,
      color: failed ? "error" : "success",
    };
  }
  if (job.isDone)
    return { text: `${name} · no longer followed`, color: "warning" };
  const phase = job.phase !== undefined ? ` · ${job.phase}` : "";
  return { text: `${name} · running${phase}`, color: "claude" };
}

export const register: Register = (on) => {
  // One poller for the session follows every log not yet finished. A reload
  // cancels it with the old module, and session.start arms it again.
  on("session.start", async ($, e, next) => {
    let isBusy = false;
    $.clock.every(POLL_MS, () => {
      if (isBusy) return;
      isBusy = true;
      void (async () => {
        const list = (await read($, logs)) ?? [];
        const now = await $.clock.now();
        for (const log of list) {
          const { value: job } = await $.state.get({ ...jobs, id: log });
          if (job?.isDone !== true)
            await poll($, log, now).catch(() => undefined);
        }
      })().finally(() => {
        isBusy = false;
      });
    });
    return next(e);
  });

  on("tool.call", async ($, e, next) => {
    const ran = await next(e);
    if (EVALUATE.test(e.tool) && !("deny" in ran && ran.deny !== undefined)) {
      const log = jobLog(ran.text ?? ran.result);
      if (log !== undefined) await followLog($, log).catch(() => undefined);
    } else if (e.tool === "Monitor") {
      const log = monitoredLog((e as { command?: unknown }).command, []);
      if (log !== undefined) await followLog($, log).catch(() => undefined);
    }
    return ran;
  });

  on(
    "ui.render",
    { component: "ToolUse", props: { tool: EVALUATE } },
    async ($, e, next) => {
      const input = e.props.input as { input?: unknown } | undefined;
      if (typeof input?.input !== "string") return next(e);
      const { Box, Button, Code, Text } = $.ui.resolve(e);
      const { title, body } = splitSource(input.input);
      const isExpanded =
        (await read($, { ...expanded, id: e.requestId })) ?? false;
      const shown = isExpanded ? body : body.slice(0, FOLDED_LINES);
      const hidden = body.length - shown.length;
      const { mark, color } = glyph(e.props);
      const log =
        e.props.output === undefined ? undefined : jobLog(e.props.output);
      const job =
        log === undefined ? undefined : await read($, { ...jobs, id: log });
      const toggle = { ...expanded, id: e.requestId };

      return (
        <Box flexDirection="column">
          <Box flexDirection="row" gap={1}>
            <Text color={color} bold>
              {mark}
            </Text>
            <Text bold wrap="truncate-end">
              {title}
            </Text>
          </Box>
          {shown.length > 0 && (
            <Box paddingLeft={2}>
              <Code
                source={shown.join("\n")}
                language="nu"
                wrap="truncate-end"
              />
            </Box>
          )}
          {(hidden > 0 || (isExpanded && body.length > FOLDED_LINES)) && (
            <Box paddingLeft={2}>
              <Button
                key="fold"
                plain
                label={
                  isExpanded ? "Fold the source" : `Show ${hidden} more lines`
                }
                onPress={() => update($, toggle, (value) => !(value ?? false))}
              />
            </Box>
          )}
          {log !== undefined &&
            jobBlock({ job, log, Box, Code, Text, withTail: false })}
        </Box>
      );
    },
  );

  on(
    "ui.render",
    { component: "ToolUse", props: { tool: "Monitor" } },
    async ($, e, next) => {
      const input = e.props.input as
        | { command?: unknown; description?: unknown }
        | undefined;
      const log = monitoredLog(input?.command, (await read($, logs)) ?? []);
      if (log === undefined) return next(e);
      const job = await read($, { ...jobs, id: log });
      if (job === undefined) return next(e);
      const { Box, Code, Text } = $.ui.resolve(e);
      const { mark, color } = glyph(e.props);
      const description =
        typeof input?.description === "string" ? input.description : "Monitor";

      return (
        <Box flexDirection="column">
          <Box flexDirection="row" gap={1}>
            <Text color={color} bold>
              {mark}
            </Text>
            <Text bold wrap="truncate-end">
              {description}
            </Text>
          </Box>
          {jobBlock({ job, log, Box, Code, Text, withTail: true })}
        </Box>
      );
    },
  );
};

type Elements = ReturnType<Dollar["ui"]["resolve"]>;

// The bordered block of a job's status line and, on the Monitor's card only,
// its log tail, so the tail is drawn once rather than on both cards.
function jobBlock(props: {
  job: NushellJob | undefined;
  log: string;
  Box: Elements["Box"];
  Code: Elements["Code"];
  Text: Elements["Text"];
  withTail: boolean;
}) {
  const { job, log, Box, Code, Text, withTail } = props;
  const summary =
    job === undefined
      ? {
          text: `${log.split("/").pop()} · waiting for output`,
          color: "subtle",
        }
      : jobSummary(job);
  return (
    <Box
      flexDirection="column"
      marginLeft={2}
      borderStyle="round"
      borderDimColor
      paddingX={1}
    >
      <Text color={summary.color} wrap="truncate-end">
        {summary.text}
      </Text>
      {withTail && job !== undefined && job.tail.length > 0 && (
        <Code source={job.tail.join("\n")} wrap="truncate-end" />
      )}
    </Box>
  );
}
