---
name: rlm
description: Process context too large to read directly (big files, logs, many files, long command output) with the Recursive Language Model pattern in the persistent Nushell MCP REPL. Keep context in Nushell variables, inspect it programmatically, and delegate slices to parallel `claude -p` sub-calls with the `rlm` commands. Use for whole-repository questions, long-log triage, and aggregation over many documents.
---

# Recursive Language Model workflow

The Nushell MCP `evaluate` tool keeps one live session. The `rlm` commands
there turn it into an RLM environment: the context is a variable, the root
agent writes Nushell to inspect it, and sub-models read only the slices they are
given. Only small results enter the agent's own context.

## Commands

| Command | Purpose |
|---|---|
| `rlm load ...globs [--text s]` | Load files or text as `{source, text}` rows |
| `rlm info` | Bytes, lines, and approximate tokens per source |
| `rlm peek -o N -l N [-n]` | A window of lines, with the total and a `truncated` flag |
| `rlm find <regex>` | Matching lines with source and zero-based line number |
| `rlm chunk [--chars N \| --lines N]` | Line-aligned chunks that keep `source` and line ranges |
| `rlm query <prompt> [--schema rec] [--recursive] [--full]` | One sub-call over the piped context |
| `rlm map <prompt> [--schema rec] [--threads N] [--max-calls N]` | Parallel sub-calls, one per chunk, in order |
| `rlm usage [--reset]` | Calls, failures, tokens, and cost from the ledger |

Each command takes context from the pipeline: a string, a list of strings,
`rlm load` or `rlm chunk` rows, or any structured value (sent as JSON).

## Loop

1. **Load without printing.** `let ctx = rlm load logs/*.log`. A `let` produces
   no output, so the text never enters your context. Then run `$ctx | rlm info`.
2. **Probe cheaply first.** Use `rlm find`, `rlm peek`, and ordinary Nushell
   (`where`, `group-by`, `lines`, `parse`) to narrow the context before paying
   for a model call. Regular expressions and structure are free.
3. **Chunk and map.** `let parts = ($ctx | rlm chunk --chars 40000)`, then
   `let notes = ($parts | rlm map "..." --schema {...})`. Pass `--schema` when
   you will combine answers in code; it returns records instead of prose.
4. **Reduce.** Combine answers with Nushell (`flatten`, `uniq`, `math sum`)
   when the task is mechanical. Otherwise pipe the compact answers into one
   more `rlm query`.
5. **Check `rlm usage`** before widening the fan-out.

Keep every large intermediate result in a `let` binding and print only
summaries. `$history.N` holds the full result of each evaluation if an output
was truncated.

## User-facing readout

Before loading or searching a large source set, give a brief commentary update
that names the source and task. Give another update before a `rlm map` or
`rlm query` that calls sub-models, and report the useful finding after it
returns. Adjacent `rlm peek`, `rlm find`, and saved-history slices can share one
readout. Describe the work in plain language so an opaque `let` binding or MCP
tool label does not hide what is happening from the user.

## Choosing the call

- `rlm query` without `--recursive` is one model turn with no tools. Use it for
  extraction, classification, and summarization of a slice that fits.
- `rlm query --recursive` gives the sub-model its own Nushell REPL with these
  commands. Its context is passed as a temp file and deleted afterwards. Use it
  for a sub-problem that itself needs search and decomposition. The sub-model
  can run arbitrary Nushell, so do not use it on untrusted content. Set
  `--max-budget-usd`.
- `RLM_MAX_DEPTH` (default 1) limits recursive nesting, and `RLM_MAX_COST_USD`
  stops new calls once the ledger reaches that spend.
- `RLM_MODEL` defaults to `haiku`. Pass `--model sonnet` for a hard
  final reduction or for recursive sub-agents that need to plan.

## Example

```nu
let ctx = rlm load **/*.nix
let chunks = ($ctx | rlm chunk --chars 30000)
let found = ($chunks | rlm map "List every systemd user service defined here." --schema {type: object, properties: {services: {type: array, items: {type: string}}}, required: [services], additionalProperties: false})
$found | where error == null | each {|r| $r.answer.services | each {|s| {service: $s, source: $r.source} } } | flatten | uniq
```
