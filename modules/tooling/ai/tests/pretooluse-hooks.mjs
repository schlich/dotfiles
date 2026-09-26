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

function run(name, stdin, mode, delay) {
  const { command, env } = hookCommand(name);
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

const claudePayload = (command, tool = "Bash") =>
  JSON.stringify({
    session_id: "test",
    hook_event_name: "PreToolUse",
    tool_name: tool,
    tool_input: { command },
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
    name: "defers nix build",
    stdin: claudePayload("nix build .#foo"),
    decision: null,
  },
  {
    hook: "prefer-nushell",
    name: "defers jj log",
    stdin: claudePayload("jj log -r @"),
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
console.log(`${results.length - failures}/${results.length} hook cases passed`);
process.exit(failures === 0 ? 0 : 1);
