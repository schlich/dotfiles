# `deploy-reverts causes`, with jev replaced by a stub that records each
# request and answers by the phase it names, so nothing reaches TypeSafe:
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

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) deploy-reverts checks failed: ($failures | str join ', ')" }
  }
  print "All deploy-reverts checks passed."
}
