# `deploy-reverts causes`, with jev replaced by a stub that records each
# request and answers by the phase it names, so nothing reaches TypeSafe,
# and `deploy-reverts notify` against a stubbed canary that hangs, refuses,
# or answers:
#   nu --no-config-file tests/deploy-reverts.nu deploy/reverts.nu jev/questions.nuon

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def answer [cause: string, confidence: float, catchable: float] {
  {
    model: "jev-1.13.0"
    answers: {
      cause: { type: choice, choice: $cause, confidence: $confidence }
      precheck_catchable: { type: noul, noul: $catchable }
    }
  } | to json --raw
}

def main [script: path, questions: path] {
  let script = ($script | path expand)
  let tmp = (mktemp --directory)
  mut failures = []

  # The stub answers a build-phase revert as an evaluation failure, a
  # watch-phase one as a failed service, and a deadman one unsurely; it
  # fails outright while FAIL is set.
  let calls = ($tmp | path join calls.jsonl)
  let build = ($tmp | path join build.json)
  let watch = ($tmp | path join watch.json)
  let other = ($tmp | path join other.json)
  answer evaluation_or_build 0.9 0.95 | save $build
  answer service_failure 0.8 0.3 | save $watch
  answer flaky_probe 0.3 0.1 | save $other
  let jev = ($tmp | path join jev)
  [
    "#!/bin/sh"
    "if [ -n \"$FAIL\" ]; then echo 'Jev request failed with HTTP 503' >&2; exit 1; fi"
    "req=$(cat)"
    $"printf '%s\\n' \"$req\" >> ($calls)"
    "case \"$req\" in"
    $"  *'\"phase\":\"build\"'*\) cat ($build) ;;"
    $"  *'\"phase\":\"watch\"'*\) cat ($watch) ;;"
    $"  *\) cat ($other) ;;"
    "esac"
  ] | str join "\n" | save $jev
  ^chmod +x $jev

  let state = ($tmp | path join state)
  let reports = ($state | path join reports)
  mkdir $reports
  let entry = {|id, phase, breached, report|
    let path = ($reports | path join $"($id).md")
    $report | save $path
    { id: $id, at: $"2026-10-1($id)T10:00:00+00:00", host: homelab, phase: $phase, rev: abc, author: me, subject: $"change ($id)", activated: ($phase != build), restored: true, breached: $breached, report: $path } | to json --raw
  }
  [
    (do $entry 1 build [build] "# homelab rejected\n\n## What breached\n\n- `build`: error: attribute 'foo' missing")
    (do $entry 2 watch [units] "# homelab reverted\n\n## Newly failed units\n\nnginx.service failed\nAPI_TOKEN=hunter2 in the environment")
    (do $entry 3 build [build] "# homelab rejected\n\n- `build`: error: infinite recursion")
    (do $entry 4 deadman [watch] "# homelab reverted\n\nThe watch died.")
  ] | str join "\n" | save ($state | path join reverts.jsonl)

  let causes = {|fail|
    with-env {
      HOME: $tmp
      DEPLOY_STATE: $state
      DEPLOY_REVERTS_QUESTIONS: ($questions | path expand)
      DEPLOY_REVERTS_JEV: $jev
      FAIL: $fail
    } { ^$nu.current-exe --no-config-file $script causes --json | complete }
  }

  let run = (do $causes "")
  $failures = ($failures | append (expect "causes exits cleanly" $run.exit_code 0))
  let result = ($run.stdout | from json)
  $failures = ($failures | append (expect "each revert gets a cause" ($result.reverts | get cause) [evaluation_or_build service_failure evaluation_or_build unsure]))
  $failures = ($failures | append (expect "causes rank by how many were catchable" $result.causes [
    { cause: evaluation_or_build, reverts: 2, catchable: 2 }
    { cause: service_failure, reverts: 1, catchable: 0 }
    { cause: unsure, reverts: 1, catchable: 0 }
  ]))
  let sent = (open --raw $calls | lines | each { from json })
  $failures = ($failures | append (expect "one jev request per revert" ($sent | length) 4))
  $failures = ($failures | append (expect "jev is asked the deploy_reverts questions" ($sent.0.questions | columns | sort) [cause precheck_catchable]))
  $failures = ($failures | append (expect "the report reaches jev" ($sent.0.state.revert.report | str contains "attribute 'foo'") true))
  $failures = ($failures | append (expect "credential lines in a report are withheld" ($sent | to json | str contains hunter2) false))

  let failed = (do $causes "1")
  $failures = ($failures | append (expect "causes survives a jev failure" $failed.exit_code 0))
  let failed_result = ($failed.stdout | from json)
  $failures = ($failures | append (expect "an unjudged revert keeps its error" ($failed_result.reverts | all {|row| $row.cause == null and ($row.error | str contains "HTTP 503") }) true))
  $failures = ($failures | append (expect "unjudged reverts stay out of the tally" $failed_result.causes []))

  let plain = (with-env { HOME: $tmp, DEPLOY_STATE: $state } { ^$nu.current-exe --no-config-file $script | complete })
  $failures = ($failures | append (expect "the plain listing still works" ($plain.exit_code == 0 and ($plain.stdout | str contains "Checks that caused reverts")) true))

  # `notify` against a canary, with ssh, systemd-run, and notify-send
  # stubbed: ssh hangs, refuses, or answers with SSH_REPLY by SSH_MODE.
  let bin = ($tmp | path join bin)
  mkdir $bin
  let ssh_log = ($tmp | path join ssh.log)
  let spawn_log = ($tmp | path join spawn.jsonl)
  let notify_log = ($tmp | path join notify.log)
  [
    "#!/bin/sh"
    $"printf '%s\\n' \"$*\" >> ($ssh_log)"
    "case \"$SSH_MODE\" in"
    "  hang\) exec sleep 300 ;;"
    "  down\) echo 'ssh: connect to host homelab port 2222: Connection refused' >&2; exit 255 ;;"
    "  *\) cat \"$SSH_REPLY\" ;;"
    "esac"
  ] | str join "\n" | save ($bin | path join ssh)
  [
    $"#!($nu.current-exe) --no-config-file"
    $"def --wrapped main [...args] { $\"\(\$args | to json --raw\)\\n\" | save --append ($spawn_log) }"
  ] | str join "\n" | save ($bin | path join systemd-run)
  [
    "#!/bin/sh"
    $"printf '%s\\n' \"$@\" >> ($notify_log)"
    "echo"
  ] | str join "\n" | save ($bin | path join notify-send)
  ^chmod +x ($bin | path join ssh) ($bin | path join systemd-run) ($bin | path join notify-send)

  let home = ($tmp | path join home)
  let quiet = ($tmp | path join quiet)
  mkdir $home $quiet
  let canary = {|id, phase| { id: ($id | into string), at: $"2026-10-2($id)T10:00:00+00:00", host: homelab, phase: $phase, rev: abc, author: me, subject: $"change ($id)", activated: true, restored: true, breached: [watch], report: $"/var/lib/nixos-switch-main/reports/($id).md", report_text: $"# homelab reverted ($id)" } }
  let reply = ($tmp | path join reply.json)
  [(do $canary 1 watch) (do $canary 2 deadman)] | to json | save $reply
  let none = ($tmp | path join none.json)
  "[]" | save $none
  let notify = {|mode, answer|
    with-env {
      HOME: $home
      XDG_STATE_HOME: null
      DEPLOY_STATE: $quiet
      DEPLOY_REVERTS_FETCH_TIMEOUT: "2"
      SSH_MODE: $mode
      SSH_REPLY: $answer
      PATH: ($env.PATH | prepend $bin)
    } {
      let started = (date now)
      let run = (^$nu.current-exe --no-config-file $script notify ssh://homelab:2222 | complete)
      $run | insert took ((date now) - $started)
    }
  }
  let cache = ($home | path join .local state deploy-reverts)

  let hung = (do $notify hang $reply)
  $failures = ($failures | append (expect "a hanging canary does not fail the run" $hung.exit_code 0))
  $failures = ($failures | append (expect "a hanging canary is cut off in bounded time" ($hung.took < 15sec) true))
  $failures = ($failures | append (expect "a hanging canary is reported as a timeout" ($hung.stderr | str contains "ssh to ssh://homelab:2222 gave no answer within 2 seconds") true))
  $failures = ($failures | append (expect "ssh goes to the OpenSSH port without prompting" (open --raw $ssh_log | str contains "-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 ssh://homelab:2222 deploy-reverts") true))

  let down = (do $notify down $reply)
  $failures = ($failures | append (expect "an unreachable canary does not fail the run" $down.exit_code 0))
  $failures = ($failures | append (expect "an unreachable canary names ssh's error" ($down.stderr | str contains "exited 255: ssh: connect to host homelab port 2222: Connection refused") true))
  $failures = ($failures | append (expect "a failed fetch announces nothing" ($spawn_log | path exists) false))
  $failures = ($failures | append (expect "a failed fetch keeps the seen stamp" ($cache | path join homelab.seen | path exists) false))

  let fetched = (do $notify ok $reply)
  $failures = ($failures | append (expect "a canary's reverts are fetched" $fetched.exit_code 0))
  $failures = ($failures | append (expect "the cache is named for the host, not the destination" (open --raw ($cache | path join homelab.jsonl) | lines | length) 2))
  $failures = ($failures | append (expect "each fetched report is kept" (open --raw ($cache | path join reports homelab 2.md)) "# homelab reverted 2"))
  $failures = ($failures | append (expect "the newest revert is marked seen" (open --raw ($cache | path join homelab.seen) | str trim) "2026-10-22T10:00:00+00:00"))
  let spawned = (open --raw $spawn_log | lines | each { from json })
  $failures = ($failures | append (expect "missed reverts are announced once, newest first" ($spawned | length) 1))
  let command = ($spawned.0 | skip until {|arg| $arg == "--" } | skip 1)
  $failures = ($failures | append (expect "the notification waits in a unit of its own" ($command | last 5) ["prompt" "homelab" "2" "--earlier" "1"]))

  let again = (do $notify ok $none)
  $failures = ($failures | append (expect "a seen revert is not announced again" ($again.exit_code == 0 and (open --raw $spawn_log | lines | length) == 1) true))

  let prompted = (with-env { HOME: $home, DEPLOY_STATE: $quiet, PATH: ($env.PATH | prepend $bin) } { ^($command | first) ...($command | skip 1) | complete })
  $failures = ($failures | append (expect "the prompt shows the revert" ($prompted.exit_code == 0 and (open --raw $notify_log | str contains "homelab reverted change 2")) true))
  $failures = ($failures | append (expect "the prompt counts the earlier reverts" (open --raw $notify_log | str contains "deadman: watch. By me (and 1 earlier).") true))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) deploy-reverts checks failed: ($failures | str join ', ')" }
  }
  print "All deploy-reverts checks passed."
}
