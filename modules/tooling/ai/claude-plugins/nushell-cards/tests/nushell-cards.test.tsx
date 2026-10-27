import { describe, expect, mock, test } from "claude-code/testing";
import type { On } from "claude-code";

import {
  cleanLine,
  jobLog,
  latestPhase,
  monitoredLog,
  parseOutcome,
  splitSource,
} from "../hooks/register.tsx";

const EVALUATE = "mcp__plugin_hm_nushell__evaluate";
const LOG = "/tmp/scratch/build.log";
const SOURCE =
  '# Build the system\njob-log $"($S)/build.log" --cwd $D { nix build path:.#foo }';
const REPLY = JSON.stringify({
  cwd: "/tmp",
  history_index: 3,
  output: { job: 1, log: LOG },
});
const OUTPUT = [{ type: "text", text: REPLY }];

describe("parsing", () => {
  test("a card is titled by its comment line", () => {
    expect(splitSource("# Check status\n\njj status")).toEqual({
      title: "Check status",
      body: ["jj status"],
    });
    expect(splitSource("ls").title).toBe("nushell");
  });

  test("a job-log result names its log", () => {
    expect(jobLog(OUTPUT)).toBe(LOG);
    expect(jobLog({ content: OUTPUT })).toBe(LOG);
    expect(jobLog(JSON.stringify({ output: [1, 2] }))).toBeUndefined();
  });

  test("a Monitor names the log it watches", () => {
    expect(monitoredLog("# Follow it\nwatch-job /var/log/ci/log", [])).toBe(
      "/var/log/ci/log",
    );
    expect(
      monitoredLog('watch-job $"($S)/build.log"', ["/a/other.log", LOG]),
    ).toBe(LOG);
    expect(monitoredLog("watch-job $log", ["/a/other.log", LOG])).toBe(LOG);
    expect(monitoredLog('watch-job --replay "/x/y.log"', [])).toBe("/x/y.log");
    expect(monitoredLog("tail -f x", [LOG])).toBeUndefined();
  });

  test("outcomes and terminal lines read cleanly", () => {
    expect(parseOutcome("{exit_code: 0}")).toEqual({ exitCode: 0 });
    expect(parseOutcome('{exit_code: 3, error: "boom, twice"}')).toEqual({
      exitCode: 3,
      error: "boom, twice",
    });
    expect(cleanLine("copying 1/9\rcopying 9/9 \x1b[1mdone\x1b[0m")).toBe(
      "copying 9/9 done",
    );
    expect(cleanLine('\x1b]7501;{"state":"x"}\x07built')).toBe("built");
    expect(
      latestPhase(
        '{"state":"running","msg":"eval"}\n{"state":"clear"}\nnot json',
      ),
    ).toBe("running · eval");
  });
});

// Files and live pids beneath the plugin, in memory.
function fakeHost(on: On) {
  const files = new Map<string, string>();
  const pids = new Set<number>();
  on("fs.stat", async (_$, e) => {
    const text = files.get(e.path);
    if (text === undefined) return { deny: `ENOENT: ${e.path}` };
    return {
      value: {
        kind: "file" as const,
        size: text.length,
        mtimeMs: 0,
        isLink: false,
      },
    };
  });
  on("fs.read", async (_$, e) => {
    const text = files.get(e.path);
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text };
  });
  on("fs.exists", async (_$, e) => ({
    value: files.has(e.path) || pids.has(Number(e.path.replace("/proc/", ""))),
  }));
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  return { files, pids };
}

const ROW = {
  tool_use_id: "toolu_build",
  tool: EVALUATE,
  input: { input: SOURCE },
  isRunning: false,
  isErrored: false,
  isInterrupted: false,
  output: OUTPUT,
};

test("a job-log card streams its log until the job ends", async ($, on) => {
  const clock = mock.clock(on, { now: 1_000 });
  const { files, pids } = fakeHost(on);
  on("tool.call", async () => ({ result: OUTPUT, text: REPLY }));
  files.set(`${LOG}.job.nuon`, '{pid: 4242, topic: "job.x"}');
  files.set(LOG, "=== build\nbuilding foo\n");
  files.set(
    `${LOG}.status.jsonl`,
    '{"state":"running","msg":"building foo"}\n',
  );
  pids.add(4242);

  await $.session.start({
    cwd: "/tmp",
    surface: "desktop",
    isInteractive: true,
  });
  await $.tool.call({
    tool: EVALUATE,
    tool_use_id: "toolu_build",
    input: SOURCE,
  });
  await clock.advance(1_000);
  await clock.settle();

  for (const surface of ["terminal", "desktop"] as const) {
    const ui = await $.ui.mount({
      plugin: "nushell-cards",
      surface,
      component: "ToolUse",
      requestId: "toolu_build",
      props: ROW,
    });
    expect(
      await ui.find({ type: "Text", text: "Build the system" }),
    ).toBeDefined();
    expect(
      await ui.find({
        type: "Text",
        text: /build\.log · running · running · building foo/,
      }),
    ).toBeDefined();
    // The log tail belongs to the Monitor's card, not the evaluation's.
    expect(
      await ui.find({ type: "Code", text: /building foo/ }),
    ).toBeUndefined();
    await ui.unmount();
  }

  // A card left open redraws as the log grows and the job ends.
  const ui = await $.ui.mount({
    plugin: "nushell-cards",
    surface: "desktop",
    component: "ToolUse",
    requestId: "toolu_build",
    props: ROW,
  });
  files.set(
    `${LOG}.status.jsonl`,
    '{"state":"running","msg":"building foo"}\n{"state":"running","msg":"building bar"}\n',
  );
  await clock.advance(1_000);
  await clock.settle();
  expect(
    await ui.find({
      type: "Text",
      text: /build\.log · running · running · building bar/,
    }),
  ).toBeDefined();

  files.set(LOG, "=== build\nbuilding foo\nbuilding bar\n/nix/store/abc-foo\n");
  files.set(`${LOG}.done.nuon`, "{exit_code: 0}");
  await clock.advance(1_000);
  await clock.settle();
  expect(
    await ui.find({ type: "Text", text: /build\.log · exit 0/ }),
  ).toBeDefined();
  expect(await ui.find({ type: "Code", text: /abc-foo/ })).toBeUndefined();

  const monitor = await $.ui.mount({
    plugin: "nushell-cards",
    surface: "desktop",
    component: "ToolUse",
    props: {
      tool_use_id: "toolu_watch",
      tool: "Monitor",
      input: {
        description: "nix build foo",
        command: '# Follow the build\nwatch-job $"($S)/build.log"',
        timeout_ms: 3_600_000,
      },
      isRunning: true,
      isErrored: false,
      isInterrupted: false,
    },
  });
  expect(
    await monitor.find({ type: "Text", text: "nix build foo" }),
  ).toBeDefined();
  expect(await monitor.find({ type: "Code", text: /abc-foo/ })).toBeDefined();
});

test("a job whose Nushell exits without an outcome reads as lost", async ($, on) => {
  const clock = mock.clock(on, { now: 1_000 });
  const { files } = fakeHost(on);
  on("tool.call", async () => ({ result: OUTPUT, text: REPLY }));
  files.set(`${LOG}.job.nuon`, '{pid: 4242, topic: "job.x"}');
  files.set(LOG, "evaluating\n");

  await $.session.start({
    cwd: "/tmp",
    surface: "desktop",
    isInteractive: true,
  });
  await $.tool.call({
    tool: EVALUATE,
    tool_use_id: "toolu_build",
    input: SOURCE,
  });
  await clock.advance(1_000);
  await clock.settle();

  const ui = await $.ui.mount({
    plugin: "nushell-cards",
    surface: "desktop",
    component: "ToolUse",
    requestId: "toolu_build",
    props: ROW,
  });
  expect(await ui.find({ type: "Text", text: /lost/ })).toBeDefined();
});

test("a long source folds behind a button on every surface", async ($) => {
  const body = Array.from({ length: 12 }, (_, index) => `print ${index}`);
  for (const surface of ["terminal", "desktop", "vscode", "mobile"] as const) {
    const ui = await $.ui.mount({
      plugin: "nushell-cards",
      surface,
      component: "ToolUse",
      props: {
        ...ROW,
        tool_use_id: `toolu_${surface}`,
        input: { input: ["# Print a dozen", ...body].join("\n") },
        output: undefined,
      },
    });
    expect((await ui.find({ key: "fold" }))?.props.label).toBe(
      "Show 9 more lines",
    );
    expect((await ui.find({ type: "Code" }))?.text).not.toMatch(/print 11/);
    await ui.press({ key: "fold" });
    expect((await ui.find({ key: "fold" }))?.props.label).toBe(
      "Fold the source",
    );
    expect((await ui.find({ type: "Code" }))?.text).toMatch(/print 11/);
    await ui.unmount();
  }
});

test("other tools draw as the engine draws them", async ($, on) => {
  on("ui.render", async ($, e) => {
    const { Text } = $.ui.resolve(e);
    return <Text>engine row</Text>;
  });
  const ui = await $.ui.mount({
    plugin: "nushell-cards",
    surface: "desktop",
    component: "ToolUse",
    props: {
      tool_use_id: "toolu_read",
      tool: "Read",
      input: { file_path: "/x" },
      isRunning: false,
      isErrored: false,
      isInterrupted: false,
    },
  });
  expect(await ui.find({ type: "Text", text: "engine row" })).toBeDefined();
});
