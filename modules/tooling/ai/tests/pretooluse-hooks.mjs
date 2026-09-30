// Run each installed PreToolUse hook the way Claude Code and Copilot CLI do:
// the hooks.json command through `sh -c`, with the payload written to a
// Node-created stdin. Node gives children a socketpair, not a pipe, which is
// what broke `open /dev/stdin`, so every case also runs from a plain file.
//
// Usage: node pretooluse-hooks.mjs <plugin-name>=<plugin-dir>...
import { spawn } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  openSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const plugins = Object.fromEntries(
  process.argv.slice(2).map((arg) => {
    const [name, dir] = arg.split("=");
    return [name, dir];
  }),
);

function hookCommand(name) {
  const dir = plugins[name];
  if (!dir) throw new Error(`no plugin directory given for ${name}`);
  // Claude Code plugins keep hooks/hooks.json; Copilot plugins keep hooks.json.
  const file = existsSync(join(dir, "hooks", "hooks.json"))
    ? join(dir, "hooks", "hooks.json")
    : join(dir, "hooks.json");
  const hooks = JSON.parse(readFileSync(file, "utf8")).hooks;
  // Claude Code uses PreToolUse with nested hooks; Copilot uses preToolUse.
  const claude = hooks.PreToolUse?.find((entry) => entry.matcher === "Bash")
    ?.hooks?.[0]?.command;
  const copilot = hooks.preToolUse?.find(
    (entry) => entry.matcher === "bash",
  )?.command;
  const command = claude ?? copilot;
  if (!command) throw new Error(`${name} declares no Bash PreToolUse command`);
  return { command, env: { ...process.env, COPILOT_PLUGIN_ROOT: dir } };
}

const scratch = mkdtempSync(join(tmpdir(), "pretooluse-hooks-"));

// The Stop hook that raises never-reviewed Bash use cases.
function stopCommand() {
  const dir = plugins["prefer-nushell"];
  const hooks = JSON.parse(
    readFileSync(join(dir, "hooks", "hooks.json"), "utf8"),
  ).hooks;
  const command = hooks.Stop?.[0]?.hooks?.[0]?.command;
  if (!command) throw new Error("prefer-nushell declares no Stop command");
  return { command, env: process.env };
}

function run(name, stdin, mode, delay, hook = hookCommand(name)) {
  const { command, env } = hook;
  return new Promise((resolve, reject) => {
    let input = "pipe";
    if (mode === "file") {
      const path = join(
        scratch,
        `${name}-${Math.random().toString(36).slice(2)}.json`,
      );
      writeFileSync(path, stdin);
      input = openSync(path, "r");
    }
    const child = spawn("sh", ["-c", command], {
      env,
      stdio: [input, "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => (stdout += data));
    child.stderr.on("data", (data) => (stderr += data));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    if (mode === "socket") {
      // A hook that exits without reading closes the socket; report it via the result.
      child.stdin.on("error", () => {});
      setTimeout(() => child.stdin.end(stdin), delay);
    }
  });
}

const claudePayload = (
  command,
  tool = "Bash",
  { background = false, event = "PreToolUse" } = {},
) =>
  JSON.stringify({
    session_id: "test",
    hook_event_name: event,
    tool_name: tool,
    tool_use_id: "toolu_test",
    tool_input: { command, run_in_background: background },
    cwd: "/tmp",
  });
const copilotPayload = (command) =>
  JSON.stringify({ toolName: "bash", toolArgs: { command } });

// `decision`: null means the hook stays silent; `stderr` is a required prefix
// for the one-line diagnostic, or null when stderr must be empty.
const cases = [
  {
    hook: "jj-guard",
    name: "denies git commit",
    stdin: claudePayload("git commit -m x"),
    decision: "deny",
  },
  {
    hook: "jj-guard",
    name: "denies chained git push",
    stdin: claudePayload("jj log; git push"),
    decision: "deny",
  },
  {
    hook: "jj-guard",
    name: "allows read-only git",
    stdin: claudePayload("git log --oneline"),
    decision: null,
  },
  {
    hook: "jj-guard",
    name: "allows ls",
    stdin: claudePayload("ls"),
    decision: null,
  },
  {
    hook: "jj-guard",
    name: "asks on malformed JSON",
    stdin: "not json",
    decision: "ask",
    stderr: "guard-git-writes: ",
  },
  {
    hook: "jj-guard",
    name: "asks on empty stdin",
    stdin: "",
    decision: "ask",
    stderr: "guard-git-writes: ",
  },
  {
    hook: "copilot-guard",
    name: "denies git reset",
    stdin: copilotPayload("git reset --hard"),
    copilot: "deny",
  },
  {
    hook: "copilot-guard",
    name: "allows jj status",
    stdin: copilotPayload("jj status"),
    copilot: "allow",
  },
  {
    hook: "prefer-nushell",
    name: "denies ls",
    stdin: claudePayload("ls"),
    decision: "deny",
    reason: /Nushell MCP tool/,
  },
  {
    hook: "prefer-nushell",
    name: "denies a text pipeline",
    stdin: claudePayload("cat f | grep x | head -5"),
    decision: "deny",
    reason: /cat, grep, head/,
  },
  {
    hook: "prefer-nushell",
    name: "denies prefixed rg",
    stdin: claudePayload("FOO=1 sudo rg x src"),
    decision: "deny",
  },
  {
    hook: "prefer-nushell",
    name: "denies command substitution",
    stdin: claudePayload("echo $(find . -name x)"),
    decision: "deny",
  },
  {
    hook: "prefer-nushell",
    name: "denies a foreground nix build",
    stdin: claudePayload("nix build .#foo"),
    decision: "deny",
    reason: /Nushell job/,
  },
  {
    hook: "prefer-nushell",
    name: "denies a background nix build",
    stdin: claudePayload("nix build .#foo", "Bash", { background: true }),
    decision: "deny",
    reason: /job spawn/,
  },
  {
    hook: "prefer-nushell",
    name: "denies a background ci land after cd",
    stdin: claudePayload("cd ws && ci land > land.log 2>&1", "Bash", {
      background: true,
    }),
    decision: "deny",
    reason: /job spawn/,
  },
  {
    hook: "prefer-nushell",
    name: "defers another background command",
    stdin: claudePayload("cargo build --release", "Bash", { background: true }),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "defers sudo nix",
    stdin: claudePayload("sudo nix store gc", "Bash", { background: true }),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "denies text tools in the background",
    stdin: claudePayload("tail -f build.log", "Bash", { background: true }),
    decision: "deny",
    reason: /tail/,
  },
  {
    hook: "prefer-nushell",
    name: "denies a foreground jj log",
    stdin: claudePayload("jj log -r @"),
    decision: "deny",
  },
  {
    hook: "prefer-nushell",
    name: "defers sudo",
    stdin: claudePayload("sudo nixos-rebuild switch --flake .#asus"),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "denies a text tool under sudo",
    stdin: claudePayload("sudo cat /etc/shadow"),
    decision: "deny",
    reason: /cat/,
  },
  {
    hook: "prefer-nushell",
    name: "logs PostToolUse silently",
    stdin: claudePayload("nix build .#foo", "Bash", { event: "PostToolUse" }),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "exempts jev",
    stdin: claudePayload("jev bash-guard"),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "exempts an iwe heredoc",
    stdin: claudePayload(
      "iwe create note --strict --content - <<'EOF'\n# Note\n\nsort the imports first\nEOF",
    ),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "denies a text tool before iwe",
    stdin: claudePayload("cat x | iwe create note --content -"),
    decision: "deny",
  },
  {
    hook: "prefer-nushell",
    name: "asks on malformed JSON",
    stdin: "{",
    decision: "ask",
    stderr: "prefer-nushell: ",
  },
  // Jev cases stop before the network request.
  {
    hook: "jev-bash-guard",
    name: "ignores other tools",
    stdin: claudePayload("ls", "Read"),
    empty: true,
  },
  {
    hook: "jev-bash-guard",
    name: "withholds credentials",
    stdin: claudePayload('$env.GITHUB_TOKEN = "x"'),
    decision: "ask",
    reason: /credential/,
  },
  {
    hook: "jev-bash-guard",
    name: "asks on blank command",
    stdin: claudePayload("   "),
    decision: "ask",
    reason: /could not be inspected/,
  },
  {
    hook: "jev-bash-guard",
    name: "asks on malformed JSON",
    stdin: "[",
    decision: "ask",
    stderr: "jev bash-guard: ",
  },
];

const transports = [
  { mode: "socket", delay: 0 },
  { mode: "socket", delay: 200 },
  { mode: "file", delay: 0 },
];

function check(testCase, result) {
  const problems = [];
  if (result.code !== 0) problems.push(`exit ${result.code}`);
  // Claude Code shows only the first stderr line; a Nushell trace there is the bug.
  if (/nu::shell::/.test(result.stderr))
    problems.push("stderr contains a Nushell error trace");
  if (testCase.stderr) {
    if (!result.stderr.startsWith(testCase.stderr))
      problems.push(
        `stderr should start with ${JSON.stringify(testCase.stderr)}`,
      );
    if (result.stderr.trim().includes("\n"))
      problems.push("stderr should be one line");
  } else if (result.stderr !== "") {
    problems.push("stderr should be empty");
  }

  const stdout = result.stdout.trim();
  let output = null;
  if (stdout !== "") {
    try {
      output = JSON.parse(stdout);
    } catch {
      problems.push("stdout is not JSON");
    }
  }
  if (testCase.copilot) {
    if (output?.permissionDecision !== testCase.copilot)
      problems.push(`expected Copilot decision ${testCase.copilot}`);
  } else if (testCase.empty) {
    if (output && Object.keys(output).length > 0)
      problems.push("expected an empty decision");
  } else if (testCase.decision === null) {
    if (output && Object.keys(output).length > 0)
      problems.push("expected no decision");
  } else {
    const specific = output?.hookSpecificOutput;
    if (specific?.hookEventName !== "PreToolUse")
      problems.push("missing hookSpecificOutput.hookEventName");
    if (specific?.permissionDecision !== testCase.decision)
      problems.push(`expected decision ${testCase.decision}`);
    if (
      typeof specific?.permissionDecisionReason !== "string" ||
      specific.permissionDecisionReason === ""
    ) {
      problems.push("missing permissionDecisionReason");
    } else if (
      testCase.reason &&
      !testCase.reason.test(specific.permissionDecisionReason)
    ) {
      problems.push(`reason should match ${testCase.reason}`);
    }
  }
  return problems;
}

let failures = 0;
const results = await Promise.all(
  cases.flatMap((testCase) =>
    transports.map(async (transport) => ({
      testCase,
      transport,
      result: await run(
        testCase.hook,
        testCase.stdin,
        transport.mode,
        transport.delay,
      ),
    })),
  ),
);
for (const { testCase, transport, result } of results) {
  const label = `${testCase.hook}: ${testCase.name} [${transport.mode}${transport.delay ? ` +${transport.delay}ms` : ""}]`;
  const problems = check(testCase, result);
  if (problems.length === 0) {
    console.log(`ok   ${label}`);
  } else {
    failures += 1;
    console.log(`FAIL ${label}: ${problems.join("; ")}`);
    console.log(`     stdout: ${JSON.stringify(result.stdout)}`);
    console.log(`     stderr: ${JSON.stringify(result.stderr)}`);
  }
}
// Every well-formed prefer-nushell payload appends one log line.
const logPath = join(
  process.env.HOME,
  ".local",
  "state",
  "claude-code",
  "bash-requests.jsonl",
);
const expectedLines = results.filter(
  ({ testCase }) =>
    testCase.hook === "prefer-nushell" && testCase.decision !== "ask",
).length;
const logged = existsSync(logPath)
  ? readFileSync(logPath, "utf8").trim().split("\n").map(JSON.parse)
  : [];
if (logged.length === expectedLines) {
  console.log(`ok   prefer-nushell: logs ${expectedLines} requests`);
} else {
  failures += 1;
  console.log(
    `FAIL prefer-nushell: expected ${expectedLines} log lines, got ${logged.length}`,
  );
}
if (!logged.some((entry) => entry.event === "ran")) {
  failures += 1;
  console.log("FAIL prefer-nushell: PostToolUse was not logged as ran");
}

// The Stop hook reads the log written above, so these run in order: the
// silent cases first, then the first raise, then the repeat it suppresses.
const stopPayload = (session, active = false) =>
  JSON.stringify({
    session_id: session,
    hook_event_name: "Stop",
    stop_hook_active: active,
  });
const stopCases = [
  {
    name: "stays silent when switched off",
    stdin: stopPayload("test"),
    env: { CLAUDE_BASH_FEEDBACK: "off" },
    block: null,
  },
  {
    name: "stays silent when a Stop hook is already active",
    stdin: stopPayload("test", true),
    block: null,
  },
  {
    name: "stays silent for a session without Bash requests",
    stdin: stopPayload("other"),
    block: null,
  },
  {
    name: "raises new use cases",
    stdin: stopPayload("test"),
    block: /long_jobs · nix[\s\S]*bash-feedback skill/,
  },
  {
    name: "raises each use case once",
    stdin: stopPayload("test"),
    block: null,
  },
];
for (const testCase of stopCases) {
  const hook = stopCommand();
  const result = await run("stop-hook", testCase.stdin, "socket", 0, {
    command: hook.command,
    env: { ...hook.env, ...testCase.env },
  });
  const problems = [];
  if (result.code !== 0) problems.push(`exit ${result.code}`);
  if (result.stderr !== "") problems.push("stderr should be empty");
  const stdout = result.stdout.trim();
  if (testCase.block === null) {
    if (stdout !== "") problems.push("expected no output");
  } else {
    let output = null;
    try {
      output = JSON.parse(stdout);
    } catch {
      problems.push("stdout is not JSON");
    }
    if (output?.decision !== "block") problems.push("expected decision block");
    if (!testCase.block.test(output?.reason ?? ""))
      problems.push(`reason should match ${testCase.block}`);
  }
  const label = `stop-hook: ${testCase.name}`;
  if (problems.length === 0) {
    console.log(`ok   ${label}`);
  } else {
    failures += 1;
    console.log(`FAIL ${label}: ${problems.join("; ")}`);
    console.log(`     stdout: ${JSON.stringify(result.stdout)}`);
    console.log(`     stderr: ${JSON.stringify(result.stderr)}`);
  }
}

const total = results.length + 2 + stopCases.length;
console.log(`${total - failures}/${total} hook cases passed`);
process.exit(failures === 0 ? 0 : 1);
