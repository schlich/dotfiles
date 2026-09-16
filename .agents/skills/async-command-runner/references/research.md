# Research survey: asynchronous command execution for agents

This survey informs `async-command-runner`. It was checked on 2026-09-15.
The sources use several different meanings of “async”; the design should not
collapse them into one feature.

## The useful taxonomy

| Layer | What becomes non-blocking | What must be preserved |
| --- | --- | --- |
| Language/runtime async | A coroutine yields while I/O or a child process runs | task handle, cancellation, timeout, structured ownership |
| Tool-call async | Model generation continues while a tool executes | tool-call ID, interrupt/event, result correlation, ordering/dependencies |
| Process/job async | The agent session returns while an OS process continues | command, cwd, logs, PID/group, exit status, artifacts |
| Durable execution | Work survives worker/session/machine failure | event history or checkpoint, retry policy, idempotency, signals, timers |
| Agent async multitasking | Independent subtasks progress concurrently | task graph, shared state, fairness, bounded resources, user-visible status |

The proposed skill implements the third layer directly, borrows cancellation,
timeouts, structured ownership, and futures from the first two, and offers a
small local approximation of the fourth. It should recommend a real durable
workflow engine when the requirements exceed that approximation.

## Agent and LLM literature

### Superlogical CLI demo (watched 2026-09-15)

The relevant post is Mitchell Hashimoto's [“New week new demo!” CLI
walkthrough](https://x.com/mitchellh/status/2099622049325232505). I watched
the complete 7:31 video in a browser with captions enabled. The demo's
important architectural signal is not a particular command spelling: the CLI
is presented as a first-class way to control the multiplexer, with the same
capabilities available in the GUI, specifically to support automation,
editors, and agentic coding tools. The screen shows work organized in
terminal/session blocks and controlled from the CLI rather than treated as an
unowned background PID.

This is consistent with Superlogical's published design: a [durable session
around the work](https://www.superlogical.com/) that spans interactive,
automatic, and production modes while remaining visible and controllable by
people. The video does not establish undocumented APIs or a guarantee that
every command is durable, so this survey does not infer exact Superlogical
subcommands from pixels.

**Implication:** make “session/block” the local abstraction around a long
command. Give the agent a stable session and block identity, provide CLI-like
operations for launch/list/inspect/attach/cancel/result, and keep human
visibility separate from machine observation. Use existing tmux or Zellij
facilities rather than inventing a second opaque process layer.

### Existing multiplexer primitives

[tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode) is a
text protocol over which a client sends normal tmux commands and receives
asynchronous `%output` notifications. tmux also provides
[pane snapshots and piping](https://github.com/tmux/tmux/wiki/Advanced-Use/ae175537241de0f59acbd9a08bba4bb33a3c4487).
[Zellij's programmatic control](https://zellij.dev/documentation/programmatic-control.html)
offers JSON inspection, pane IDs, `dump-screen` snapshots, `subscribe`
streams, and explicit blocking/exit-status actions.

**Transfer to the skill:** use named sessions for reconnectability, pane IDs
for correlation, snapshots for recovery, and event streams for low-latency
progress. Add flow control/backpressure and bound the amount of terminal data
fed to the model. These tools improve client/session continuity; they do not
by themselves provide event-sourced recovery after host loss.

### Asynchronous LLM Function Calling (AsyncLM, 2024)

[Gim, Lee, and Zhong, arXiv:2412.07017](https://arxiv.org/abs/2412.07017)
identifies the usual synchronous function-call loop as a latency bottleneck.
Its design lets the model generate and execute calls concurrently and uses
interrupts to notify in-flight inference when calls return. It reports lower
end-to-end latency on function-calling benchmarks.

**Implication:** a runner should correlate each result with a stable job ID and
allow completion events to be consumed later. Merely returning “started” is
not enough; the parent agent needs an explicit completion event or pollable
handle. The paper concerns tool/model interaction, not OS process durability.

### Recursive Language Models (RLM, 2025)

[Zhang, Kraska, and Khattab, arXiv:2512.24601](https://arxiv.org/abs/2512.24601)
treat long prompts as an external environment that the model can inspect,
decompose, and recursively process. This is primarily an inference-time
scaling and context-management strategy.

**Implication:** RLM is adjacent, not the direct solution to long builds. The
same architectural instinct is valuable: keep large logs and execution state
outside the conversational context, query only relevant slices, and recurse
or delegate independent analysis when useful. Do not describe RLM as a job
queue, scheduler, or guarantee of process survival.

### Recursive Agent Harnesses (2026)

[Lumer et al., arXiv:2606.13643](https://arxiv.org/abs/2606.13643) extends
recursion from model calls to full agent harnesses with filesystem tools, code
execution, planning, and parallel subagents.

**Implication:** independent work can be fanned out, but the parent needs
explicit fan-in and dependency tracking. This supports a task-graph ledger;
it does not justify unbounded subprocess or subagent spawning.

### AsyncTool benchmark (2026)

[Shi et al., arXiv:2605.27995](https://arxiv.org/abs/2605.27995) evaluates
asynchronous tool calling under delayed feedback and multiple heterogeneous
tasks. Its framing emphasizes task switching, dependency tracking, state
maintenance, and efficiency metrics such as completion and coordination.

**Implication:** evaluate this skill on more than wall-clock speed: measure
correct result correlation, no duplicate launches, dependency correctness,
recovery after interruption, cancellation latency, and context/log volume.
Delayed feedback is a reasoning problem as well as a systems problem.

### Practical background-run APIs

[LangGraph Agent Protocol background runs](https://langchain-ai.github.io/agent-protocol/)
defines fire-and-forget plus polling/streaming, and CRUD operations for agent
executions including list, get, cancel, and delete. [LangGraph task
documentation](https://langchain-ai.github.io/langgraph/how-tos/wait-user-input-functional/)
adds checkpointed task results for resumption.

**Implication:** a useful local command interface should expose at least
launch, list/get, poll/attach, cancel, and result retrieval. A job record is an
API boundary even if the implementation is just a terminal session.

## Standard async and systems techniques

### Futures, tasks, and structured concurrency

[Python asyncio tasks](https://docs.python.org/3/library/asyncio-task.html)
distinguish a coroutine from a scheduled task and expose task handles,
`gather`, `TaskGroup`, timeouts, and cancellation. Event loops use cooperative
scheduling: a task that awaits gives other tasks a chance to run. `TaskGroup`
provides stronger failure containment than unstructured gathering by
cancelling sibling tasks when one fails.

**Transfer to command jobs:** return a handle, never confuse scheduling with
completion, scope child jobs, bound waits, and define sibling-failure policy.
An OS process cannot be assumed to honor language-level cancellation, so the
runner must additionally manage process groups and verify termination.

### Subprocess creation and waiting

[Python asyncio subprocesses](https://docs.python.org/3/library/asyncio-subprocess.html)
provide asynchronous process creation, stream readers, and an asynchronous
`wait`; the docs also warn that buffered reads are unsuitable for unlimited
output and recommend explicit timeout/cancellation handling. POSIX
[`posix_spawn`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/posix_spawn.html)
returns a child PID, while [`wait`](https://pubs.opengroup.org/onlinepubs/9699919799/functions/wait.html)
collects termination status for a direct child.

**Transfer to command jobs:** use argument vectors where possible, stream or
redirect output with bounded buffering, retain the child identity, and collect
the actual exit status. A PID alone is not a durable job identity and a stale
PID must never be killed.

### Queues, backpressure, retries, and observability

[Prefect tasks](https://docs.prefect.io/v3/concepts/tasks) make task-run state,
futures, retries, caching, concurrency, and timeouts first-class. Its
[task-runner model](https://docs.prefect.io/v3/concepts/task-runners) separates
submission from execution and lets callers retrieve results later. Celery's
[task guide](https://docs.celeryq.dev/en/main/userguide/tasks.html) is a
longstanding queue-based example with task IDs, result backends, retry state,
and revoke/cancel semantics.

**Transfer to command jobs:** add a concurrency budget and output backpressure;
make retries explicit and bounded; keep status and results queryable; and
separate observation timeout from execution timeout. Caching is only safe when
inputs and side effects are understood.

### Durable execution and event history

[Temporal](https://docs.temporal.io/) models workflows as durable executions
that resume after crashes, with activities, retries, signals, timers, and
event history. Its [workflow execution model](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/workflow/workflow-execution/workflow-execution.mdx)
uses replay of recorded history, and its [activity model](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-execution.mdx)
documents retries, timeouts, heartbeats, and cancellation.

**Transfer to command jobs:** persist state transitions and an audit trail,
make retries idempotent or compensate side effects, use heartbeats/progress
when a command can run for a long time, and model user cancellation as a
signal. A manifest plus log is a pragmatic local ledger, not equivalent to
Temporal's replay guarantees.

## Design conclusion

The skill should use a progressive escalation path:

1. synchronous call for quick or interactive work;
2. native terminal session/job handle for a command that merely outlives the
   current reasoning step;
3. detached process plus manifest, logs, and process-group supervision when it
   must survive the terminal/session;
4. a queue or durable workflow engine for multi-machine execution, human
   pauses, long-lived retries, high fan-out, or externally visible side effects.

The core invariant is: **the agent can stop waiting without losing the ability
to establish what happened**. RLM-style externalized context helps keep logs
out of the prompt; async function calling helps keep inference moving; durable
execution supplies the stronger recovery semantics when local bookkeeping is
not enough.
