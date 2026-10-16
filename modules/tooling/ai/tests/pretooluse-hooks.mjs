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

function hookCommand(name, extraEnv = {}) {
  const dir = plugins[name];
  if (!dir) throw new Error(`no plugin directory given for ${name}`);
  const env = {
    ...process.env,
    COPILOT_PLUGIN_ROOT: dir,
    ...hookEnv[name],
    ...extraEnv,
  };
  // Jev is not a hook of its own: prefer-nushell runs `jev bash-guard` on
  // the calls its policy defers.
  if (name === "jev") return { command: `${dir}/bin/jev bash-guard`, env };
  // Claude Code plugins keep hooks/hooks.json; Copilot plugins keep hooks.json.
  const file = existsSync(join(dir, "hooks", "hooks.json"))
    ? join(dir, "hooks", "hooks.json")
    : join(dir, "hooks.json");
  const hooks = JSON.parse(readFileSync(file, "utf8")).hooks;
  // Claude Code uses PreToolUse with nested hooks; Copilot uses preToolUse.
  // Claude Code reads a matcher as a regex over the whole tool name.
  const claude = hooks.PreToolUse?.find((entry) =>
    new RegExp(`^(?:${entry.matcher})$`).test("Bash"),
  )?.hooks?.[0]?.command;
  const copilot = hooks.preToolUse?.find(
    (entry) => entry.matcher === "bash",
  )?.command;
  const command = claude ?? copilot;
  if (!command) throw new Error(`${name} declares no Bash PreToolUse command`);
  return { command, env };
}

const scratch = mkdtempSync(join(tmpdir(), "pretooluse-hooks-"));

// prefer-nushell asks Jev about the calls its policy defers. A stub stands in
// for the network model: it records each payload it is sent and answers with
// JEV_STUB_DECISION (default ask), or fails when that is `fail`.
const jevStub = join(scratch, "jev-stub");
const jevCalls = join(scratch, "jev-calls.jsonl");
writeFileSync(
  jevStub,
  `#!/bin/sh
payload=$(cat)
printf '%s\\n' "$payload" >> "$JEV_STUB_CALLS"
decision=\${JEV_STUB_DECISION:-ask}
if [ "$decision" = fail ]; then echo "stub Jev failed" >&2; exit 3; fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"Jev stub ran %s"}}\\n' "$decision" "$1"
`,
  { mode: 0o755 },
);
const hookEnv = {
  "prefer-nushell": { CLAUDE_BASH_JEV: jevStub, JEV_STUB_CALLS: jevCalls },
};

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
  { background = false, event = "PreToolUse", session = "test" } = {},
) =>
  JSON.stringify({
    session_id: session,
    hook_event_name: event,
    tool_name: tool,
    tool_use_id: "toolu_test",
    tool_input: { command, run_in_background: background },
    cwd: "/tmp",
  });
const nushellPayload = (input) =>
  JSON.stringify({
    session_id: "test",
    hook_event_name: "PreToolUse",
    tool_name: "mcp__plugin_hm_nushell__evaluate",
    tool_use_id: "toolu_test",
    tool_input: { input },
    cwd: "/tmp",
  });
const copilotPayload = (command) =>
  JSON.stringify({ toolName: "bash", toolArgs: { command } });

// `decision`: null means the hook stays silent; `stderr` is a required prefix
// for the one-line diagnostic, or null when stderr must be empty; `env` adds
// to the hook's environment; `jev` marks a call prefer-nushell sends to Jev.
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
    name: "denies git push from Nushell",
    stdin: nushellPayload("# Push\n^git push origin main | complete"),
    decision: "deny",
  },
  {
    hook: "jj-guard",
    name: "denies nested git commit from Nushell",
    stdin: nushellPayload("let r = (git commit -m x | complete)"),
    decision: "deny",
  },
  {
    hook: "jj-guard",
    name: "allows read-only git from Nushell",
    stdin: nushellPayload("^git log --oneline | complete"),
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
    name: "denies a bare true probe",
    stdin: claudePayload("true", "Bash", { session: "noop" }),
    decision: "deny",
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
    name: "points an interpreter read at the Read tool",
    stdin: claudePayload(
      "python3 << 'EOF'\nprint(open('result.txt').read())\nEOF",
    ),
    decision: "deny",
    reason: /Read tool's offset and limit/,
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
    reason: /job-log/,
  },
  {
    hook: "prefer-nushell",
    name: "denies a background ci land after cd",
    stdin: claudePayload("cd ws && ci land > land.log 2>&1", "Bash", {
      background: true,
    }),
    decision: "deny",
    reason: /job-log/,
  },
  {
    hook: "prefer-nushell",
    name: "leaves another background command to Jev",
    stdin: claudePayload("cargo build --release", "Bash", { background: true }),
    decision: "ask",
    reason: /^Jev stub ran bash-guard$/,
    jev: true,
  },
  {
    hook: "prefer-nushell",
    name: "leaves sudo nix to Jev",
    stdin: claudePayload("sudo nix store gc", "Bash", { background: true }),
    decision: "ask",
    reason: /^Jev stub/,
    jev: true,
  },
  {
    hook: "prefer-nushell",
    name: "passes on Jev's denial",
    stdin: claudePayload("cargo test", "Bash", { background: true }),
    env: { JEV_STUB_DECISION: "deny" },
    decision: "deny",
    reason: /^Jev stub/,
    jev: true,
  },
  {
    hook: "prefer-nushell",
    name: "asks when Jev fails",
    stdin: claudePayload("cargo check", "Bash", { background: true }),
    env: { JEV_STUB_DECISION: "fail" },
    decision: "ask",
    reason: /^Jev could not judge this Bash call: stub Jev failed\./,
    jev: true,
  },
  {
    hook: "prefer-nushell",
    name: "asks when Jev is missing",
    stdin: claudePayload("cargo doc", "Bash", { background: true }),
    env: { CLAUDE_BASH_JEV: join(scratch, "missing-jev") },
    decision: "ask",
    reason: /^Jev could not judge this Bash call/,
  },
  {
    hook: "prefer-nushell",
    name: "stays silent on a deferred call without Jev",
    stdin: claudePayload("cargo fmt", "Bash", { background: true }),
    env: { CLAUDE_BASH_JEV: "" },
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
    name: "leaves sudo to Jev",
    stdin: claudePayload("sudo nixos-rebuild switch --flake .#asus"),
    decision: "ask",
    reason: /^Jev stub/,
    jev: true,
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
    decision: "ask",
    reason: /^Jev stub/,
    jev: true,
  },
  {
    hook: "prefer-nushell",
    name: "exempts an iwe heredoc",
    stdin: claudePayload(
      "iwe create note --strict --content - <<'EOF'\n# Note\n\nsort the imports first\nEOF",
    ),
    decision: "ask",
    reason: /^Jev stub/,
    jev: true,
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
  // `jev bash-guard` itself; these cases stop before the network request.
  {
    hook: "jev",
    name: "ignores other tools",
    stdin: claudePayload("ls", "Read"),
    empty: true,
  },
  {
    hook: "jev",
    name: "withholds credentials",
    stdin: claudePayload('$env.GITHUB_TOKEN = "x"'),
    decision: "ask",
    reason: /credential/,
  },
  {
    hook: "jev",
    name: "asks on blank command",
    stdin: claudePayload("   "),
    decision: "ask",
    reason: /could not be inspected/,
  },
  {
    hook: "jev",
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
        hookCommand(testCase.hook, testCase.env),
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
// Every well-formed prefer-nushell payload appends one log line; a malformed
// one only reports on stderr.
const logPath = join(
  process.env.HOME,
  ".local",
  "state",
  "claude-code",
  "bash-requests.jsonl",
);
const expectedLines = results.filter(
  ({ testCase }) => testCase.hook === "prefer-nushell" && !testCase.stderr,
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
// Jev sees each deferred call once per transport and nothing the policy
// denied, so a denial never costs a model call or loses its reason to Jev's.
const jevExpected = results
  .filter(({ testCase }) => testCase.jev)
  .map(({ testCase }) => JSON.parse(testCase.stdin).tool_input.command)
  .sort();
const jevAsked = (
  existsSync(jevCalls)
    ? readFileSync(jevCalls, "utf8").trim().split("\n").map(JSON.parse)
    : []
)
  .map((payload) => payload.tool_input?.command)
  .sort();
if (JSON.stringify(jevAsked) === JSON.stringify(jevExpected)) {
  console.log(
    `ok   prefer-nushell: asks Jev about only the ${jevExpected.length} deferred calls`,
  );
} else {
  failures += 1;
  console.log(
    `FAIL prefer-nushell: Jev was asked about ${JSON.stringify(jevAsked)}, expected ${JSON.stringify(jevExpected)}`,
  );
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
    name: "stays silent for a session with only a no-op probe",
    stdin: stopPayload("noop"),
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

// agent-trust: the PermissionRequest hook with a stub Jev and a seeded
// ledger, then the outcome hook that records an approved dialog.
function trustCommand(event) {
  const dir = plugins["agent-trust"];
  const hooks = JSON.parse(
    readFileSync(join(dir, "hooks", "hooks.json"), "utf8"),
  ).hooks;
  const command = hooks[event]?.[0]?.hooks?.[0]?.command;
  if (!command) throw new Error(`agent-trust declares no ${event} command`);
  return command;
}
function stubJev(name, intent) {
  const path = join(scratch, `jev-${name}`);
  const response = JSON.stringify({
    answers: {
      action_class: { choice: "read_only", confidence: 0.95 },
      needs_user_intent: { noul: intent },
    },
    model: "stub",
  });
  writeFileSync(
    path,
    `#!/bin/sh\ncat > /dev/null\nprintf '%s' '${response}'\n`,
    {
      mode: 0o755,
    },
  );
  return path;
}
const routineJev = stubJev("routine", 0.05);
const personalJev = stubJev("personal", 0.9);
// Nushell reads JSON as NUON, so the test policy is written as JSON.
function trustPolicy(mode) {
  const path = join(scratch, `trust-policy-${mode}.nuon`);
  writeFileSync(
    path,
    JSON.stringify({
      mode,
      enforce_classes: ["read_only"],
      pending_minutes: 10,
      half_life_days: 30,
      min_samples: 8,
      z: 1.645,
      tiers: { low: 0.8, medium: 0.9, high: 0.97 },
      classes: { read_only: "low", system_change: "floor" },
      max_user_intent: 0.4,
      floors: [{ tool: "^Bash$", input: "\\bsudo\\b", why: "Privileged" }],
    }),
  );
  return path;
}
// `approvals` dialogs answered an hour ago, each followed by its run.
function seededLog(name, approvals) {
  const path = join(scratch, `trust-${name}.jsonl`);
  const ts = new Date(Date.now() - 3600_000).toISOString();
  const lines = [];
  for (let i = 0; i < approvals; i++) {
    const id = `seed${i}`;
    lines.push({
      ts,
      event: "request",
      tool_use_id: id,
      tool_name: "Read",
      class: "read_only",
      decision: "ask",
      enforced: false,
    });
    lines.push({ ts, event: "ran", tool_use_id: id });
  }
  writeFileSync(
    path,
    lines.map((line) => `${JSON.stringify(line)}\n`).join(""),
  );
  return path;
}
const readLog = (path) =>
  existsSync(path)
    ? readFileSync(path, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map(JSON.parse)
    : [];
const permissionPayload = (tool, input) =>
  JSON.stringify({
    session_id: "test",
    hook_event_name: "PermissionRequest",
    tool_name: tool,
    tool_input: input,
    tool_use_id: "toolu_trust",
    cwd: "/tmp",
    permission_mode: "default",
  });
const readPayload = permissionPayload("Read", { file_path: "/tmp/x" });
const trustState = join(scratch, "trust-state");
const trustEnv = (log, mode, jev) => ({
  ...process.env,
  AGENT_TRUST_LOG: log,
  AGENT_TRUST_POLICY: trustPolicy(mode),
  AGENT_TRUST_JEV: jev,
  XDG_STATE_HOME: trustState,
});
// `allow`: the hook answers the dialog; `logged`: the reason it records.
const trustCases = [
  {
    name: "leaves a malformed payload to the user",
    stdin: "[",
    env: trustEnv(seededLog("malformed", 15), "enforce", routineJev),
    allow: false,
    stderr: "agent-trust: ",
  },
  {
    name: "applies floors before Jev",
    stdin: permissionPayload("Bash", { command: "sudo ls" }),
    env: trustEnv(seededLog("floor", 15), "enforce", routineJev),
    allow: false,
    logged: /^floor: Privileged/,
  },
  {
    name: "asks during a cold start",
    stdin: readPayload,
    env: trustEnv(seededLog("cold", 3), "enforce", routineJev),
    allow: false,
    logged: /^cold start/,
  },
  {
    name: "asks when evidence is too thin for the tier",
    stdin: readPayload,
    env: trustEnv(seededLog("thin", 9), "enforce", routineJev),
    allow: false,
    logged: /below low tier/,
  },
  {
    name: "approves a trusted class",
    stdin: readPayload,
    env: trustEnv(seededLog("trusted", 15), "enforce", routineJev),
    allow: true,
    logged: /clears low tier/,
  },
  {
    name: "leaves a matter of intent to the user",
    stdin: readPayload,
    env: trustEnv(seededLog("intent", 15), "enforce", personalJev),
    allow: false,
    logged: /needs your intent/,
  },
  {
    name: "only records in shadow mode",
    stdin: readPayload,
    env: trustEnv(seededLog("shadow", 15), "shadow", routineJev),
    allow: false,
    logged: /clears low tier/,
  },
];
let trustTotal = 0;
function report(label, problems, result) {
  trustTotal += 1;
  if (problems.length === 0) {
    console.log(`ok   ${label}`);
  } else {
    failures += 1;
    console.log(`FAIL ${label}: ${problems.join("; ")}`);
    if (result) {
      console.log(`     stdout: ${JSON.stringify(result.stdout)}`);
      console.log(`     stderr: ${JSON.stringify(result.stderr)}`);
    }
  }
}
for (const testCase of trustCases) {
  const result = await run("agent-trust", testCase.stdin, "socket", 0, {
    command: trustCommand("PermissionRequest"),
    env: testCase.env,
  });
  const problems = [];
  if (result.code !== 0) problems.push(`exit ${result.code}`);
  if (/nu::shell::/.test(result.stderr))
    problems.push("stderr contains a Nushell error trace");
  if (testCase.stderr) {
    if (!result.stderr.startsWith(testCase.stderr))
      problems.push(
        `stderr should start with ${JSON.stringify(testCase.stderr)}`,
      );
  } else if (result.stderr !== "") {
    problems.push("stderr should be empty");
  }
  const stdout = result.stdout.trim();
  if (testCase.allow) {
    let output = null;
    try {
      output = JSON.parse(stdout);
    } catch {
      problems.push("stdout is not JSON");
    }
    const specific = output?.hookSpecificOutput;
    if (specific?.hookEventName !== "PermissionRequest")
      problems.push("missing hookSpecificOutput.hookEventName");
    if (specific?.decision?.behavior !== "allow")
      problems.push("expected behavior allow");
  } else if (stdout !== "") {
    problems.push("expected no output");
  }
  if (testCase.logged) {
    const request = readLog(testCase.env.AGENT_TRUST_LOG)
      .filter((entry) => entry.event === "request")
      .at(-1);
    if (request?.tool_use_id !== "toolu_trust")
      problems.push("the dialog was not logged");
    else if (!testCase.logged.test(request.reason ?? ""))
      problems.push(
        `logged reason ${JSON.stringify(request.reason)} should match ${testCase.logged}`,
      );
  }
  report(`agent-trust: ${testCase.name}`, problems, result);
}

// The cold-start case left a dialog marker; its run is an approval, and a
// run without a dialog is not logged.
const outcomeLog = trustCases[2].env.AGENT_TRUST_LOG;
for (const [name, id, expected] of [
  ["records the run that answers a dialog", "toolu_trust", "ran"],
  ["ignores a run without a dialog", "toolu_other", null],
]) {
  const before = readLog(outcomeLog).length;
  const result = await run(
    "agent-trust",
    JSON.stringify({
      session_id: "test",
      hook_event_name: "PostToolUse",
      tool_name: "Read",
      tool_input: { file_path: "/tmp/x" },
      tool_use_id: id,
    }),
    "socket",
    0,
    { command: trustCommand("PostToolUse"), env: trustCases[2].env },
  );
  const problems = [];
  if (result.code !== 0) problems.push(`exit ${result.code}`);
  if (result.stderr !== "") problems.push("stderr should be empty");
  const added = readLog(outcomeLog).slice(before);
  if (expected === null) {
    if (added.length !== 0) problems.push("expected no log line");
  } else if (
    added.length !== 1 ||
    added[0].event !== expected ||
    added[0].tool_use_id !== id
  ) {
    problems.push(`expected one ${expected} line for ${id}`);
  }
  report(`agent-trust: ${name}`, problems, result);
}

const total = results.length + 3 + stopCases.length + trustTotal;
console.log(`${total - failures}/${total} hook cases passed`);
process.exit(failures === 0 ? 0 : 1);
