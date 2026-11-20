# How the staged switch in deploy/switch.nu judges the units a candidate
# touched, from the properties `systemctl show` reports for each kind of
# unit. A socket reports no NRestarts and a target no Result either, and on
# 2026-10-29 that crashed homelab's watch when nixbot.socket restarted:
#   nu --no-config-file tests/staged-switch-units.nu deploy/switch.nu

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def main [script: path] {
  let script = ($script | path expand)
  let cases = [
    [name row broke];
    ["a running service" { Id: a.service, ActiveState: active, SubState: running, Result: success, NRestarts: "0" } false]
    ["a service systemd is restarting" { Id: a.service, ActiveState: activating, SubState: auto-restart, Result: exit-code, NRestarts: "0" } true]
    ["a service systemd restarted on its own" { Id: a.service, ActiveState: active, SubState: running, Result: success, NRestarts: "2" } true]
    ["a oneshot that stopped without succeeding" { Id: a.service, ActiveState: inactive, SubState: dead, Result: exit-code, NRestarts: "0" } true]
    ["a listening socket, which has no restart count" { Id: a.socket, ActiveState: active, SubState: listening, Result: success } false]
    ["a failed socket" { Id: a.socket, ActiveState: failed, SubState: failed, Result: resources } true]
    ["a waiting timer" { Id: a.timer, ActiveState: active, SubState: waiting, Result: success } false]
    ["a reached target, which keeps no result" { Id: a.target, ActiveState: active, SubState: active } false]
    ["a stopped target" { Id: a.target, ActiveState: inactive, SubState: dead } false]
  ]
  # deploy/switch.nu is a script; sourcing it defines its commands without
  # running main.
  let judged = (^$nu.current-exe --no-config-file -c $"source '($script)'; '($cases | get row | to json --raw)' | from json | each {|row| unit-broke $row } | to json --raw" | complete)
  mut failures = (expect "every unit's state can be judged" $judged.exit_code 0)
  if $judged.exit_code == 0 {
    for case in ($cases | merge ($judged.stdout | from json | wrap judged)) {
      $failures = ($failures | append (expect $case.name $case.judged $case.broke))
    }
  } else {
    print $judged.stderr
  }
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) staged-switch unit checks failed: ($failures | str join ', ')" }
  }
  print "All staged-switch unit checks passed."
}
