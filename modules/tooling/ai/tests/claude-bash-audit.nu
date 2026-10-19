# claude-bash-audit's report, with jev replaced by a stub that records each
# request and answers from a fixture, so nothing reaches TypeSafe:
#   nu --no-config-file tests/claude-bash-audit.nu scripts/claude-bash-audit.nu ../../../jev/questions.nuon

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def main [script: path, questions: path] {
  let script = ($script | path expand)
  let tmp = (mktemp --directory)
  mut failures = []

  # A stub `jev ask`: it appends each request to `calls`, answers with
  # `answer`, and fails while FAIL is set.
  let calls = ($tmp | path join calls.jsonl)
  let answer = ($tmp | path join answer.json)
  let jev = ($tmp | path join jev)
  $"#!/bin/sh\nif [ -n \"$FAIL\" ]; then echo 'Jev request failed with HTTP 503' >&2; exit 1; fi\ncat >> ($calls)\necho >> ($calls)\ncat ($answer)\n" | save $jev
  ^chmod +x $jev
  let answer_with = {|choice, confidence|
    { model: "jev-1.13.0", answers: { remedy: { type: choice, choice: $choice, confidence: $confidence } } } | to json | save --force $answer
  }
  let sent = {|| if ($calls | path exists) { open --raw $calls | lines | where {|line| $line | str trim | is-not-empty } | each { from json } } else { [] } }

  let log = ($tmp | path join bash-requests.jsonl)
  let request = {|id, rule, program, command, decision|
    { ts: "2026-10-18T10:00:00+00:00", event: request, session_id: s1, tool_use_id: $id, command: $command, programs: [$program], decision: $decision, rule: $rule } | to json --raw
  }
  [
    (do $request t1 text_tools grep "grep -rn TODO modules" deny)
    (do $request t2 text_tools grep "GITHUB_TOKEN=ghp_test grep -r token ." deny)
    (do $request t3 long_jobs nix "nix build path:.#foo" deny)
  ] | str join "\n" | save $log

  let report = {|...flags|
    with-env {
      HOME: $tmp
      XDG_STATE_HOME: ($tmp | path join state)
      CLAUDE_BASH_LOG: $log
      CLAUDE_BASH_AUDIT_QUESTIONS: ($questions | path expand)
      CLAUDE_BASH_AUDIT_JEV: $jev
    } { ^$nu.current-exe --no-config-file $script report --json ...$flags | complete }
  }

  do $answer_with instruction_gap 0.9
  let plain = (do $report)
  $failures = ($failures | append (expect "report without --jev exits cleanly" $plain.exit_code 0))
  $failures = ($failures | append (expect "report without --jev asks nobody" (do $sent | length) 0))
  $failures = ($failures | append (expect "report without --jev has no remedy" ($plain.stdout | from json | get clusters | columns | any {|c| $c == remedy }) false))

  let judged = (do $report "--jev")
  let clusters = ($judged.stdout | from json | get clusters)
  $failures = ($failures | append (expect "report --jev labels each cluster" ($clusters | select rule remedy) [
    { rule: text_tools, remedy: instruction_gap }
    { rule: long_jobs, remedy: instruction_gap }
  ]))
  let calls_made = (do $sent)
  $failures = ($failures | append (expect "one jev request per cluster" ($calls_made | length) 2))
  $failures = ($failures | append (expect "jev is asked the bash_feedback questions" ($calls_made.0.questions | columns) [remedy]))
  $failures = ($failures | append (expect "examples that assign a credential are withheld" ($calls_made | where state.cluster.rule == text_tools | get 0.state.cluster.examples) ["grep -rn TODO modules"]))

  do $answer_with needs_bash 0.4
  let unsure = (do $report "--jev" | get stdout | from json | get clusters)
  $failures = ($failures | append (expect "a low-confidence answer is unsure" ($unsure | get remedy | uniq) [unsure]))

  let failed = (with-env { FAIL: "1" } { do $report "--jev" })
  $failures = ($failures | append (expect "the report survives a jev failure" $failed.exit_code 0))
  let failed_clusters = ($failed.stdout | from json | get clusters)
  $failures = ($failures | append (expect "a failed cluster has no remedy" ($failed_clusters | get remedy | uniq) [null]))
  $failures = ($failures | append (expect "a failed cluster carries the reason" ($failed_clusters.0.remedy_error | str contains "HTTP 503") true))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) claude-bash-audit checks failed: ($failures | str join ', ')" }
  }
  print "All claude-bash-audit checks passed."
}
