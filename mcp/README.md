# Nushell agent modules

This directory holds the Nushell modules that the interactive shell and the
Nushell MCP server load (`modules/programs/shell.nix`), plus the cross.stream
bootstrap run by the `xs-bootstrap` user service (`modules/home/services.nix`).
MCP servers themselves are configured declaratively in `modules/tooling/ai/`.

## Agent shell results

The configured Nushell MCP server exposes the `agent-shell` command. Use it
when an agent needs to run a terminal command and receive a stable structured
result instead of parsing terminal text:

```nu
agent-shell "jj status"
agent-shell "nix fmt -- --check" --max-output 4000
```

It returns a `nushell.ai/v1` record containing `ok`, `kind`, `command`, `cwd`,
`exit_code`, separate `stdout` and `stderr`, truncation flags, and a summary.
The command runs in a clean child Nushell with startup configuration and
history disabled. The MCP server keeps the record structured for the agent;
the same command is also available in an interactive Nushell session.

Atuin output capture is enabled for interactive sessions: its daemon keeps
recent output in memory and its Nushell `pty-proxy` associates that output with
the Atuin history ID. The `atuin` MCP server is configured for the AI clients,
so a triage agent can call `atuin_history` and `atuin_output` to inspect the
failed command's actual terminal output.

## Recursive language model commands

`rlm.nu` adds the Recursive Language Model pattern to the same persistent
REPL. Long context stays in Nushell variables instead of the agent's prompt,
and slices go to headless `claude -p` sub-calls:

```nu
let ctx = rlm load src/**/*.rs
$ctx | rlm info
let hits = ($ctx | rlm find 'unsafe')
let answers = ($ctx | rlm chunk | rlm map "List unsafe blocks and why they are needed.")
$answers | to json | rlm query "Summarize the unsafe usage across the crate."
rlm usage
```

The native `nushell` MCP server provides this REPL to Codex Desktop. It does
not require a separate Nu Pair plugin; installing that plugin exposes a second
copy of the evaluator with a misleading tool label.

`rlm query --recursive` gives the sub-model its own Nushell MCP REPL with these
commands, bounded by `RLM_MAX_DEPTH` (default 1). Sub-calls default to
`RLM_MODEL` (`haiku`), run `RLM_THREADS` (4) at a time in `rlm map`, and append
cost and token usage to `RLM_LEDGER`; set `RLM_MAX_COST_USD` to stop new calls
once the ledger reaches that spend. The `rlm` skill describes the workflow.

## Interactive terminal events

The Nushell configuration also publishes interactive command lifecycle events
to cross.stream. Atuin remains the source of truth for command history,
duration, working directory, session, and exit status; XS stores the event
workflow and correlates events using Atuin's `ATUIN_HISTORY_ID`.

The user service starts the local store at
`~/.local/share/cross.stream/store` and registers a `terminal-triage` actor.
Failed commands produce a `terminal.command.failed` event. If `ai-run` is
available, the actor sends a read-only triage request to it and records the
response. If it is unavailable, the actor records a
`terminal.agent.unconfigured` warning instead.

Intelli-shell remains in the normal Nushell input path. Commands it generates
or fixes are therefore recorded by Atuin and observed by XS without a second
execution path.
