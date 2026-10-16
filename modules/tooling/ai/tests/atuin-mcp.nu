# Replay Claude Code's MCP handshake against atuin through
# mcp-legacy-handshake: `server/discover` first, then `initialize` and
# `tools/list`. Also say when bare atuin answers the 2026-07-28 tools/list
# with the fields that version requires, so the wrapper can go.
#
# Usage: nu atuin-mcp.nu WRAPPER ATUIN

def converse [messages: list<record>, ...command: string] {
    $messages
    | each {|message| { jsonrpc: "2.0" } | merge $message | to json --raw }
    | str join "\n"
    | ^timeout 20 ...$command
    | complete
    | get stdout
    | lines
    | each {|line| $line | from json }
}

def main [wrapper: string, atuin: string] {
    let replies = (converse [
        { id: "probe" method: "server/discover" params: {} }
        { id: 0 method: "initialize" params: { protocolVersion: "2025-11-25" capabilities: {} clientInfo: { name: "check" version: "0" } } }
        { method: "notifications/initialized" }
        { id: 1 method: "tools/list" }
    ] $wrapper $atuin mcp)

    let discover = ($replies | where id? == "probe" | first)
    if $discover.error?.code? != -32601 {
        error make { msg: $"server/discover reached atuin: ($discover | to nuon)" }
    }
    let agreed = ($replies | where id? == 0 | first | get result.protocolVersion)
    if $agreed != "2025-11-25" {
        error make { msg: $"initialize agreed on ($agreed), not 2025-11-25" }
    }
    let tools = ($replies | where id? == 1 | first | get result.tools.name)
    for tool in [atuin_history atuin_output] {
        if $tool not-in $tools {
            error make { msg: $"tools/list lacks ($tool): ($tools | to nuon)" }
        }
    }
    print $"ok: wrapped atuin lists ($tools | str join ', ')"

    let meta = {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28"
        "io.modelcontextprotocol/clientCapabilities": {}
    }
    let bare = (converse [
        { id: "probe" method: "server/discover" params: { _meta: $meta } }
        { id: 1 method: "tools/list" params: { _meta: $meta } }
    ] $atuin mcp | where id? == 1 | get --optional 0.result | default {})
    if "ttlMs" in $bare and "cacheScope" in $bare {
        print "note: atuin now answers the 2026-07-28 tools/list in full; remove mcp-legacy-handshake"
    }
}
