# Tests for scripts/mcp.nu and scripts/secret.nu, which sit beside this
# directory. A stub `secretspec` on PATH stands in for the keyring.
#
# Usage: nu mcp-probe.nu

use std/assert

const scripts = (path self | path dirname | path join .. scripts)
const fake_server = (path self | path dirname | path join fake-mcp-server.nu)
source ($scripts | path join mcp.nu)
source ($scripts | path join secret.nu)

def stub-secretspec [dir: path] {
    mkdir $dir
    "#!/bin/sh
case \"$*\" in
  *MISSING*) echo \"Secret 'MISSING' not found\" >&2; exit 1 ;;
  *) echo 'hunter2' ;;
esac
" | save -f ($dir | path join secretspec)
    chmod +x ($dir | path join secretspec)
}

def main [] {
    # A JSON body, an array body, and an event stream all yield their messages.
    assert equal ('{"jsonrpc":"2.0","id":1,"result":{}}' | mcp parse-replies | get id) [1]
    assert equal ('[{"id":1},{"id":2}]' | mcp parse-replies | get id) [1 2]
    let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n\n"
    assert equal ($sse | mcp parse-replies | get id) [2]
    assert equal ("" | mcp parse-replies) []
    print "ok: parse-replies"

    # Errors and a missing initialize reply are reported, not summarized.
    assert error { [{ id: 1, error: { code: -32600, message: "bad" } }] | mcp summarize }
    assert error { [{ id: 2, result: { tools: [] } }] | mcp summarize }
    print "ok: summarize"

    # End to end against a stdio server; descriptions keep their first line.
    let probe = (mcp probe stdio --wait 1sec nu --stdin $fake_server)
    assert equal $probe.server.name "fake"
    assert equal $probe.protocol "2025-11-25"
    assert equal $probe.tools [{ name: "echo", description: "Repeat the input." } { name: "add", description: "" }]
    print "ok: probe stdio"

    # Without --stdin the server reads nothing and never answers.
    let failure = (try { mcp probe stdio --wait 1sec nu $fake_server; "no error" } catch {|e| $e.msg })
    assert str contains $failure "never answered initialize"
    print "ok: probe stdio failure"

    # secret with passes the value in and returns what the closure derives,
    # but refuses to return the value itself or to run without one.
    let bin = ($env.TMPDIR? | default "/tmp" | path join mcp-probe-stub)
    stub-secretspec $bin
    with-env { PATH: ($env.PATH | prepend $bin) } {
        assert equal (secret with KEY --reason test {|v| $v | str length }) 7
        assert error { secret with KEY --reason test {|v| { header: $v } } }
        assert error { secret with MISSING --reason test {|v| 1 } }
    }
    print "ok: secret with"
}
