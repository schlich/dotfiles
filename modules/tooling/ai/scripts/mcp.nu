# Check that an MCP server answers and see which tools it offers, without
# registering it with a client: `initialize`, then `tools/list`.

# Commands for talking to MCP servers directly.
def mcp [] { help mcp }

# The JSON-RPC messages in an MCP reply body, which is either JSON or a
# server-sent event stream with one message per `data:` line.
def "mcp parse-replies" []: string -> list<record> {
    let body = ($in | str trim)
    if ($body | is-empty) { return [] }
    if ($body | str starts-with "{") or ($body | str starts-with "[") {
        let parsed = ($body | from json)
        return (if ($parsed | describe) =~ '^(list|table)' { $parsed } else { [$parsed] })
    }
    $body
    | lines
    | where $it starts-with "data:"
    | each {|line| $line | str substring 5.. | str trim | from json }
}

# The summary both probes return, from the replies to `initialize` (id 1)
# and `tools/list` (id 2).
def "mcp summarize" []: list<record> -> record {
    let replies = $in
    let failed = ($replies | where error? != null)
    if ($failed | is-not-empty) {
        error make { msg: $"the server answered with an error: ($failed | first | get error | to nuon)" }
    }
    let init = ($replies | where id? == 1 | get --optional 0.result)
    if $init == null {
        error make { msg: "the server never answered initialize" }
    }
    let tools = ($replies | where id? == 2 | get --optional 0.result.tools | default [])
    {
        server: ($init.serverInfo? | default {})
        protocol: $init.protocolVersion?
        tools: ($tools | each {|tool| { name: $tool.name, description: ($tool.description? | default "" | lines | get --optional 0 | default "") } })
    }
}

def "mcp messages" [protocol: string]: nothing -> list<record> {
    [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: $protocol, capabilities: {}, clientInfo: { name: "mcp-probe", version: "1" } } }
        { jsonrpc: "2.0", method: "notifications/initialized" }
        { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    ]
}

# Probe an MCP server over streamable HTTP.
#
# Pass credentials as --headers; read them with `secret with` so they stay
# out of the output:
#   secret with STITCH_API_KEY --reason 'probe Stitch' {|key| mcp probe http https://stitch.googleapis.com/mcp --headers {X-Goog-Api-Key: $key} }
def "mcp probe http" [
    url: string
    --headers: record = {}          # Extra request headers, such as an API key
    --protocol: string = "2025-11-25"  # Protocol version to offer in initialize
    --timeout: duration = 30sec     # Per-request timeout
]: nothing -> record {
    let base = ($headers | merge { Accept: "application/json, text/event-stream" })
    let send = {|message: record, session: any|
        let h = (if $session == null { $base } else { $base | merge { Mcp-Session-Id: $session } })
        let r = (http post --full --allow-errors --raw --max-time $timeout --content-type application/json --headers $h $url ($message | to json --raw))
        if $r.status >= 400 {
            error make { msg: $"($message.method) got HTTP ($r.status) from ($url)", help: ($r.body | into string | str substring 0..400) }
        }
        $r
    }
    let messages = (mcp messages $protocol)
    let init = (do $send ($messages | get 0) null)
    let session = ($init.headers.response | where name =~ '(?i)^mcp-session-id$' | get --optional 0.value)
    do $send ($messages | get 1) $session | ignore
    let list = (do $send ($messages | get 2) $session)
    [$init.body $list.body] | each { into string | mcp parse-replies } | flatten | mcp summarize
}

# Probe an MCP server over stdio by starting COMMAND.
#
#   mcp probe stdio --wait 15sec nix run .#playwright-mcp -- --headless
#
# Stdin stays open for --wait after the last request so slow servers can
# answer before it closes; the server is killed after --timeout. Put the
# probe's flags before COMMAND: everything after it goes to the server.
def --wrapped "mcp probe stdio" [
    ...command: string
    --protocol: string = "2025-11-25"  # Protocol version to offer in initialize
    --wait: duration = 10sec        # How long to keep stdin open after the last request
    --timeout: duration = 60sec     # Kill the server after this long
]: nothing -> record {
    if ($command | is-empty) { error make { msg: "give the command that starts the server" } }
    let lines = (mcp messages $protocol | each { to json --raw })
    let count = ($lines | length)
    # `to text` writes each line to the server as the generator yields it; a
    # list piped straight into an external is rendered as a table instead.
    let seconds = ($timeout / 1sec | math ceil)
    let run = (
        generate {|i|
            if $i < $count {
                { out: ($lines | get $i), next: ($i + 1) }
            } else if $i == $count {
                sleep $wait
                { next: ($i + 1) }
            } else { {} }
        } 0
        | to text
        | ^timeout $seconds ...$command
        | complete
    )
    let replies = ($run.stdout | lines | where $it starts-with "{" | each { from json })
    if ($replies | where id? == 1 | is-empty) {
        error make { msg: $"($command | first) never answered initialize; exit code ($run.exit_code)", help: ($run.stderr | str trim | lines | last 5 | str join "\n") }
    }
    $replies | mcp summarize
}
