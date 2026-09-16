use std/assert

let root = (mktemp -d)
cd $root
let cli = $env.PAIR_CLI
def call [command: string, ...args: string] {
    let encoded = ($args | each {|arg| $arg | to nuon} | str join " ")
    let function = {eval: "pair-eval", inspect: "pair-inspect", add: "pair-add", promote: "pair-promote", run: "pair-run", check: "pair-check", status: "pair-status"} | get $command
    ^nu --no-config-file --no-history -c $"source ($cli); ($function) ($encoded) | to nuon" | complete
}

let evaluated = (call "eval" "[ {name: 'a', n: 1}, {name: 'b', n: 2} ] | where n > 1")
assert equal $evaluated.exit_code 0
let scratch = ($evaluated.stdout | from nuon)
assert equal $scratch.status "ok"
assert (($scratch.type | str starts-with "table<"))
assert (($scratch.id | str starts-with "scratch-"))
assert (".pair/session.nuon" | path exists)
let inspected = (call "inspect" $scratch.id "schema")
assert equal $inspected.exit_code 0
assert (($inspected.stdout | from nuon).columns | is-not-empty)
let promoted = (call "promote" $scratch.id "selected")
assert equal $promoted.exit_code 0
assert (".pair/units/selected.nu" | path exists)
let checked = (call "check")
assert equal $checked.exit_code 0
assert (($checked.stdout | from nuon).0.status == "valid")
let ran = (call "run" "selected")
assert equal $ran.exit_code 0
assert equal (($ran.stdout | from nuon).status) "ok"
let status = (call "status" | get stdout | from nuon)
assert equal ($status.managed_units | length) 1
assert (($status.recent_runs | length) == 1)
let invalid = (call "eval" "this is not valid nu")
assert ($invalid.exit_code == 0)
assert equal (($invalid.stdout | from nuon).status) "error"
let missing = (call "inspect" "scratch-missing")
assert ($missing.exit_code != 0)
let failed_promotion = (call "promote" "scratch-missing" "never-created")
assert ($failed_promotion.exit_code != 0)
let failed_run = (call "run" "missing-unit")
assert ($failed_run.exit_code != 0)
"corrupt" | save -f ".pair/session.nuon"
let corrupt = (call "status")
assert ($corrupt.exit_code != 0)
print "pair lifecycle tests passed"
