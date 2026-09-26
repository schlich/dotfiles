# Recursive Language Model (RLM) helpers for the persistent Nushell MCP REPL.
#
# The root agent keeps long context in REPL variables instead of its prompt,
# inspects it with ordinary Nushell, and sends slices to sub-model calls. Sub-
# calls use headless `claude -p`; `--recursive` gives the sub-model its own
# Nushell MCP REPL with these commands, bounded by RLM_MAX_DEPTH.

const default_system = "You answer a question about the supplied context. Use only the context. If the context does not contain the answer, say so briefly. Be concise."

const recursive_system = "You are a recursive language model working in a persistent Nushell REPL exposed as the `evaluate` tool. The context is too large to read directly: load it into a variable with `let ctx = rlm load <path>`, inspect it with `rlm info`, `rlm peek`, `rlm find`, and ordinary Nushell, split it with `rlm chunk`, and delegate slices with `rlm query` or `rlm map`. Keep large values in `let` bindings instead of printing them. Finish with a concise final answer as plain text."

export-env {
    $env.RLM_MODEL = ($env.RLM_MODEL? | default "haiku")
    # Strings, because child `claude` and `nu --mcp` processes inherit them.
    $env.RLM_THREADS = ($env.RLM_THREADS? | default "4" | into string)
    $env.RLM_DEPTH = ($env.RLM_DEPTH? | default "0" | into string)
    $env.RLM_MAX_DEPTH = ($env.RLM_MAX_DEPTH? | default "1" | into string)
    $env.RLM_LEDGER = ($env.RLM_LEDGER? | default ($nu.temp-dir | path join $"rlm-($nu.pid).jsonl"))
}

# Render any context value as the text a sub-model reads.
def to-context []: any -> string {
    let value = $in
    match ($value | describe --detailed | get type) {
        "string" => $value
        "nothing" => ""
        "list" | "table" => {
            if ($value | is-empty) {
                ""
            } else if ($value | all {|row| ($row | describe) == "string" }) {
                $value | str join "\n\n"
            } else if ("text" in ($value | columns)) {
                $value | each {|row|
                    let label = ($row.source? | default ($row.index? | default ""))
                    if ($label | is-empty) { $row.text } else { $"==> ($label) <==\n($row.text)" }
                } | str join "\n\n"
            } else {
                $value | to json
            }
        }
        _ => ($value | to json)
    }
}

def ledger-total []: nothing -> float {
    if not ($env.RLM_LEDGER | path exists) { return 0.0 }
    open --raw $env.RLM_LEDGER | lines | where $it != "" | reduce --fold 0.0 {|line, acc| $acc + ($line | from json | get cost_usd) }
}

# Load files or literal text as context rows of {source, text}.
#
# Bind the result instead of printing it: `let ctx = rlm load src/**/*.rs`.
export def "rlm load" [
    ...paths: string  # Files or glob patterns to load.
    --text (-t): string  # Literal text to load instead of, or in addition to, files.
]: nothing -> table<source: string, text: string> {
    let files = ($paths | each {|pattern|
        let matches = (glob $pattern | where {|p| ($p | path type) == "file" })
        if ($matches | is-empty) {
            error make { msg: $"rlm load: no files match ($pattern)" }
        }
        $matches
    } | flatten | uniq)
    let rows = ($files | each {|path| { source: $path, text: (open --raw $path | decode utf-8) } })
    if $text == null { $rows } else { $rows | append { source: "text", text: $text } }
}

# Summarize context size without printing it.
export def "rlm info" []: any -> table {
    let value = $in
    let rows = if (($value | describe) starts-with "table") and ("text" in ($value | columns)) {
        $value
    } else {
        [{ source: ($value | describe), text: ($value | to-context) }]
    }
    $rows | each {|row|
        let bytes = ($row.text | encode utf-8 | bytes length)
        {
            source: ($row.source? | default ($row.index? | default ""))
            bytes: ($bytes | into filesize)
            lines: ($row.text | lines | length)
            approx_tokens: ($bytes // 4)
        }
    }
}

# Return a window of context lines.
export def "rlm peek" [
    --offset (-o): int = 0  # First line to return, zero-based.
    --limit (-l): int = 200  # Maximum number of lines to return.
    --numbered (-n)  # Prefix each line with its zero-based line number.
]: any -> record {
    let all = ($in | to-context | lines)
    let window = ($all | skip $offset | first $limit)
    let text = if $numbered {
        $window | enumerate | each {|l| $"($l.index + $offset): ($l.item)" } | str join "\n"
    } else {
        $window | str join "\n"
    }
    {
        offset: $offset
        returned: ($window | length)
        total_lines: ($all | length)
        truncated: (($offset + ($window | length)) < ($all | length))
        text: $text
    }
}

# Find lines matching a regular expression, with zero-based line numbers.
export def "rlm find" [
    pattern: string  # Regular expression.
]: any -> table {
    let value = $in
    let rows = if (($value | describe) starts-with "table") and ("text" in ($value | columns)) {
        $value
    } else {
        [{ source: "", text: ($value | to-context) }]
    }
    $rows | each {|row|
        $row.text | lines | enumerate | where item =~ $pattern | each {|l|
            { source: ($row.source? | default ""), line: $l.index, text: $l.item }
        }
    } | flatten
}

# Split context into chunks on line boundaries.
#
# Accepts a string or `rlm load` rows and keeps each row's source.
export def "rlm chunk" [
    --chars (-c): int = 40000  # Maximum characters per chunk.
    --lines (-l): int  # Maximum lines per chunk; overrides --chars.
]: any -> table<index: int, source: string, start_line: int, end_line: int, text: string> {
    let value = $in
    let rows = if (($value | describe) starts-with "table") and ("text" in ($value | columns)) {
        $value
    } else {
        [{ source: "", text: ($value | to-context) }]
    }
    let chunks = ($rows | each {|row|
        let source = ($row.source? | default "")
        if $lines != null {
            $row.text | lines | enumerate | chunks $lines | each {|group|
                {
                    source: $source
                    start_line: ($group | first | get index)
                    end_line: ($group | last | get index)
                    text: ($group | get item | str join "\n")
                }
            }
        } else {
            mut out = []
            mut buf = ""
            mut start = 0
            mut n = 0
            for line in ($row.text | lines) {
                # Split a single oversized line so every chunk honours the limit.
                let pieces = if ($line | str length) > $chars {
                    0..<(($line | str length) // $chars + 1) | each {|i| $line | str substring ($i * $chars)..<(($i + 1) * $chars) } | where $it != ""
                } else {
                    [$line]
                }
                for piece in $pieces {
                    if ($buf != "") and (($buf | str length) + ($piece | str length) + 1) > $chars {
                        $out = ($out | append { source: $source, start_line: $start, end_line: ([($n - 1) $start] | math max), text: $buf })
                        $buf = ""
                        $start = $n
                    }
                    $buf = if $buf == "" { $piece } else { $buf + "\n" + $piece }
                }
                $n += 1
            }
            if $buf != "" {
                $out = ($out | append { source: $source, start_line: $start, end_line: ($n - 1), text: $buf })
            }
            $out
        }
    } | flatten)
    $chunks | enumerate | each {|c| { index: $c.index } | merge $c.item }
}

# Ask a sub-model a question about the piped context.
#
# Returns the answer text, or the structured value when --schema is given.
# Use --full for the answer with model, cost, and token usage.
export def "rlm query" [
    prompt: string  # Question or instruction for the sub-model.
    --model (-m): string  # Claude model alias or ID; defaults to $env.RLM_MODEL.
    --system (-s): string  # Replacement system prompt.
    --schema: record  # JSON Schema for a structured answer.
    --recursive (-r)  # Give the sub-model its own Nushell REPL with these commands.
    --max-budget-usd: float  # Spend cap for a recursive sub-call.
    --full (-f)  # Return a record with usage metadata.
]: any -> any {
    let context = ($in | to-context)
    let model = ($model | default $env.RLM_MODEL)
    let depth = ($env.RLM_DEPTH | into int)
    let max_depth = ($env.RLM_MAX_DEPTH | into int)
    if $recursive and ($depth >= $max_depth) {
        error make { msg: $"rlm query: recursion depth ($depth) reached RLM_MAX_DEPTH ($max_depth)" }
    }
    let max_cost = ($env.RLM_MAX_COST_USD? | default null)
    if $max_cost != null and (ledger-total) >= ($max_cost | into float) {
        error make { msg: $"rlm query: ledger spend reached RLM_MAX_COST_USD ($max_cost)" }
    }

    mut args = [
        -p
        --model $model
        --output-format json
        --tools ""
        --strict-mcp-config
        --no-session-persistence
    ]
    if $schema != null {
        $args = ($args | append [--json-schema ($schema | to json --raw)])
    }

    let context_file = if $recursive and ($context != "") {
        let path = (mktemp --tmpdir rlm-context.XXXXXX)
        $context | save --force $path
        $path
    } else {
        null
    }

    let request = if $recursive {
        let mcp = { mcpServers: { rlm: { command: "nu", args: ["--mcp"] } } } | to json --raw
        $args = ($args | append [
            --mcp-config $mcp
            --allowedTools mcp__rlm__evaluate
            --system-prompt ($system | default $recursive_system)
        ])
        if $max_budget_usd != null {
            $args = ($args | append [--max-budget-usd ($max_budget_usd | into string)])
        }
        let info = if $context_file == null {
            "No context was supplied."
        } else {
            let size = ($context | encode utf-8 | bytes length | into filesize)
            $"The context is in ($context_file) \(($size), ($context | lines | length) lines\)."
        }
        { cwd: $env.PWD, stdin: $"($info)\n\nTask: ($prompt)" }
    } else {
        $args = ($args | append [--system-prompt ($system | default $default_system)])
        let body = if $context == "" { $prompt } else { $"<context>\n($context)\n</context>\n\n($prompt)" }
        # Run outside the project so its CLAUDE.md does not inflate each call.
        { cwd: $nu.temp-dir, stdin: $body }
    }

    let args = $args
    let started = (date now)
    let result = (
        with-env { RLM_DEPTH: ($depth + 1 | into string) } {
            cd $request.cwd
            $request.stdin | ^claude ...$args | complete
        }
    )
    if $context_file != null { rm --force $context_file }

    let parsed = (try { $result.stdout | from json } catch { null })
    let failed = ($result.exit_code != 0) or ($parsed == null) or ($parsed.is_error? | default false)
    let usage = ($parsed.usage? | default {})
    let record = {
        time: $started
        depth: $depth
        model: $model
        recursive: $recursive
        ok: (not $failed)
        cost_usd: ($parsed.total_cost_usd? | default 0.0)
        input_tokens: (($usage.input_tokens? | default 0) + ($usage.cache_creation_input_tokens? | default 0) + ($usage.cache_read_input_tokens? | default 0))
        output_tokens: ($usage.output_tokens? | default 0)
        duration_ms: ($parsed.duration_ms? | default null)
        turns: ($parsed.num_turns? | default null)
    }
    ($record | to json --raw) + "\n" | save --append $env.RLM_LEDGER

    if $failed {
        let detail = ([$result.stderr ($parsed.result? | default "") ($parsed.subtype? | default "")] | where $it != "" | str join "\n" | str trim)
        error make { msg: $"rlm query failed \(exit ($result.exit_code)\): ($detail)" }
    }

    let answer = if $schema != null { $parsed.structured_output? } else { $parsed.result }
    if $full { { answer: $answer } | merge $record } else { $answer }
}

# Run the same sub-model question over every chunk in parallel.
#
# Input is a list of strings or `rlm chunk` rows. Returns each row's metadata
# with `answer` and `error` columns, in input order.
export def "rlm map" [
    prompt: string  # Question or instruction applied to each chunk.
    --model (-m): string  # Claude model alias or ID; defaults to $env.RLM_MODEL.
    --system (-s): string  # Replacement system prompt.
    --schema: record  # JSON Schema for structured answers.
    --threads (-t): int  # Concurrent sub-calls; defaults to $env.RLM_THREADS.
    --max-calls: int = 64  # Refuse larger fan-outs unless raised.
    --recursive (-r)  # Make each sub-call recursive.
]: any -> table {
    let items = ($in | enumerate | each {|it|
        if ($it.item | describe) == "string" {
            { index: $it.index, text: $it.item }
        } else {
            $it.item
        }
    })
    let count = ($items | length)
    if $count > $max_calls {
        error make { msg: $"rlm map: ($count) chunks exceeds --max-calls ($max_calls); raise it or use larger chunks" }
    }
    let threads = ($threads | default ($env.RLM_THREADS | into int))
    $items | par-each --keep-order --threads $threads {|item|
        let meta = ($item | reject text)
        try {
            let answer = ($item.text | rlm query $prompt --model=$model --system=$system --schema=$schema --recursive=$recursive)
            $meta | merge { answer: $answer, error: null }
        } catch {|err|
            $meta | merge { answer: null, error: $err.msg }
        }
    }
}

# Summarize sub-call spend recorded in the ledger.
export def "rlm usage" [
    --reset  # Delete the ledger after summarizing it.
]: nothing -> record {
    let entries = if ($env.RLM_LEDGER | path exists) {
        open --raw $env.RLM_LEDGER | lines | where $it != "" | each { from json }
    } else {
        []
    }
    let summary = {
        ledger: $env.RLM_LEDGER
        calls: ($entries | length)
        failed: ($entries | where ok == false | length)
        cost_usd: ($entries | reduce --fold 0.0 {|e, acc| $acc + $e.cost_usd })
        input_tokens: ($entries | reduce --fold 0 {|e, acc| $acc + $e.input_tokens })
        output_tokens: ($entries | reduce --fold 0 {|e, acc| $acc + $e.output_tokens })
        by_model: (if ($entries | is-empty) { [] } else {
            $entries | group-by model --to-table | each {|g|
                { model: $g.model, calls: ($g.items | length), cost_usd: ($g.items.cost_usd | math sum) }
            }
        })
    }
    if $reset { rm --force $env.RLM_LEDGER }
    $summary
}
