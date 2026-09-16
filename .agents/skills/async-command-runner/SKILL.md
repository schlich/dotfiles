---
name: async-command-runner
description: Detect builds, tests, benchmarks, installs, and other commands likely to outlive the current reasoning step, run them asynchronously with observable state, and resume, collect, or cancel them safely later. Do not use for short commands, interactive commands, or dependent steps whose output is needed immediately.
metadata:
  short-description: Run long commands in the background and resume them safely
---

# Async command runner

Use this skill whenever a shell command is plausibly long-running or its
latency is uncertain. The goal is to free the agent to do independent work
while preserving enough state to return to the command and report a trustworthy
result.

## Decide before running

Classify the command and its dependencies before invoking it:

- Run synchronously when it is expected to finish quickly, is interactive, or
  its output is required for the very next action.
- Run asynchronously when it is a build, full test suite, benchmark, large
  generation, package installation, migration, indexing job, or another
  command likely to take more than a few seconds. Treat uncertain latency as a
  reason to choose asynchronous execution.
- Do not background a command that may prompt for credentials, confirmation,
  or terminal input. Resolve the prompt or obtain explicit authorization
  first.
- Do not start a dependent command merely because its prerequisite is running.
  Record the dependency and wait for a successful completion, unless the
  command is explicitly designed to consume partial output.
- Do not run concurrent commands that write the same outputs, lock the same
  resources, mutate shared state, or compete for scarce CPU/GPU/memory without
  checking compatibility and a concurrency limit.

Prefer an existing native asynchronous/background execution facility. If the
runtime exposes only a terminal command session, start it with a short initial
wait, retain the returned session/job identifier, and continue with independent
work. If neither is available, use a detached process only when its output,
exit status, process group, and working directory can be recorded outside the
conversation.

For local work, prefer a named terminal-multiplexer session or block when one
is available. Treat the tuple `(host, multiplexer, session, block/pane)` as the
primary reconnectable identity and the PID as supplemental evidence. This
session-first shape keeps interactive work, agent processes, and background
commands visible through one control plane, which is more useful than spawning
an opaque detached process for every command.

## Job contract

Every asynchronous command is a job, not an untracked process. Capture a
manifest in the runtime's durable job store (or an explicit state directory
outside the repository) containing:

- a unique job ID;
- the exact command/argument vector, whether a shell was used, and the working
  directory;
- start time, initiating task, and a non-secret environment/toolchain summary;
- the native session ID or PID/process-group ID;
- stdout and stderr destinations, with a bounded live tail if supported;
- state, last-observed time, exit code or signal, timeout, and cancellation
  policy;
- expected artifacts and downstream jobs, if known.

Never persist access tokens, credentials, or the complete environment when a
small allowlist or fingerprint is sufficient. Prefer argument vectors over
shell strings; use a shell only when shell syntax is part of the user's
command and the runtime can preserve it faithfully.

Use these states and only advance them with evidence:

`queued -> running -> succeeded | failed | canceled | timed-out | lost`

`lost` means the job cannot currently be identified or its status cannot be
verified; it is not evidence of failure. Do not silently rerun a lost job,
especially when it may have produced external side effects.

## Run and supervise

1. Create the job record before or atomically with process launch, then verify
   that the process started in the intended directory with the intended
   command.
2. Redirect output to durable files or a bounded event stream. Avoid piping a
   large or unbounded log into the agent context. Record useful milestones,
   artifact paths, and the last output offset/timestamp when available.
3. Return promptly with the job ID, command, directory, current state, and how
   it will be checked. This is a launch acknowledgement, not a completion
   claim.
4. Continue only with work independent of the job. Keep a small dependency
   ledger: `job A` blocks `job B` until A succeeds; a failed or canceled A
   invalidates B unless the user chooses a recovery path.
5. Poll on meaningful boundaries, not in a tight loop. Use increasing intervals
   for quiet jobs, reset the interval when new output or a state change appears,
   and stop polling during unrelated work. Native session polling should use a
   bounded wait and retain the session identifier.
6. On completion, read the exit status and a relevant log slice, inspect
   expected artifacts, and distinguish command failure from supervisor failure,
   timeout, cancellation, or missing status.

Use structured concurrency ideas even when the underlying tool is a process:
scope child jobs to the parent task when appropriate, propagate cancellation
deliberately, bound concurrency and output, and clean up all children in a
group. A timeout on observation is not automatically a timeout of the job.
If the job itself has a deadline, enforce it at the process/supervisor layer
and record that fact.

## Session-first execution with existing tools

When using a terminal multiplexer as the local job substrate:

- Create or reuse a uniquely named session and a dedicated block/pane per
  independent command. Record the host, session, and pane IDs before doing
  other work.
- Prefer machine-readable control paths. With tmux, use control mode and its
  asynchronous output notifications when available; use `list-*`,
  `capture-pane`, and `pipe-pane` for state, snapshots, and logging. With
  Zellij, use its programmatic session actions, JSON pane/session inspection,
  `dump-screen`, and `subscribe` facilities when supported by the installed
  version.
- Use snapshots for reconnect and event streams for progress. Bound or pause
  a stream that is outpacing the observer; do not let terminal output flood
  the agent context.
- Keep observation read-only by default. Attach a human or send input only
  when the task requires it; cancellation and input injection are separate
  state-changing operations.
- If the command is launched inside an interactive shell, do not infer exit
  status from a prompt or a screen pattern alone. Prefer a direct child exit
  status or an explicit, unique completion sentinel written by the wrapper.
- For a remote job, establish the session on the target host and reconnect to
  that same session through SSH or the multiplexer. Record the host identity
  and connection state. A persistent session survives client disconnects, not
  necessarily host reboot or worker loss; escalate to a service manager or
  durable workflow engine when those guarantees matter.

Expose a small CLI-shaped surface even if the implementation is internal:
`launch`, `list/get`, `snapshot` or `stream`, `attach`, `cancel`, and `result`.
This gives editors, coding agents, and humans the same composable control
points and prevents the agent from having to scrape a GUI to discover state.

## Resume, cancel, and recover

When returning to the task, first enumerate active or recently changed jobs by
job ID rather than launching a duplicate. Revalidate the working directory,
process identity, and manifest before attaching or polling. Report meaningful
state changes only; unchanged background work does not need narration.

Cancellation is a user-visible state transition. Send a graceful signal to
the process group, allow the configured grace period, then use a stronger
signal only if authorized and necessary. Confirm that descendants have exited
and record the signal and cleanup result. Never kill a PID based only on a
stale or reused numeric PID.

Retry only when the command is known to be safe to repeat or has an idempotent
output strategy. For a failed build/test, capture the first actionable error
and the final status before proposing a retry. For migrations, deployments,
publishes, or other side-effecting commands, require an explicit recovery
decision and prefer a compensating action over blind retry.

If the agent session ends, the next invocation should recover from manifests
and logs, not from memory. If the process was attached to a non-durable
terminal and disappeared, mark it `lost` and explain what evidence is missing.
Do not claim that work completed merely because the launch call succeeded.

## Reporting format

For launch:

> Started `<job-id>` for `<short command>` in `<directory>`; state `running`.
> Output is recorded at `<log reference>`. Independent work can continue; the
> result will be checked when needed.

For completion, report state, exit code/signal, elapsed time, the smallest
useful error or success summary, artifacts, and any jobs unblocked by it. Link
to local logs or artifacts when the host supports file links.

For a blocked or lost job, say exactly which observation is missing and what
safe next action is available. Do not substitute a guessed result.

## Research basis

Read [references/research.md](references/research.md) when designing or
extending the runner, comparing orchestration backends, or explaining why this
skill tracks more than a PID. The short version is that RLMs and recursive
agent harnesses motivate externalizing execution/context and decomposing
independent work, while async function-calling work motivates interruptible
non-blocking tool execution. Durable workflow systems add the missing
event-history, retry, timeout, cancellation, and recovery semantics. This
skill applies those ideas conservatively to local commands without claiming
that a detached process alone provides durable execution.
