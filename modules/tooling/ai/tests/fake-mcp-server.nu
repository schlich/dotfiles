# A stdio MCP server for tests: reads requests until stdin closes, then
# answers initialize and tools/list.
def main [] {
    $in
    | lines
    | each { from json }
    | where id? != null
    | each {|request|
        let result = match $request.method {
            "initialize" => {
                protocolVersion: $request.params.protocolVersion
                capabilities: { tools: {} }
                serverInfo: { name: "fake", version: "0" }
            }
            "tools/list" => {
                tools: [
                    { name: "echo", description: "Repeat the input.\nSecond line." }
                    { name: "add", inputSchema: { type: "object" } }
                ]
            }
        }
        { jsonrpc: "2.0", id: $request.id, result: $result } | to json --raw
    }
    | str join "\n"
}
