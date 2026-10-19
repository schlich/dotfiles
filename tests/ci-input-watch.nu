# ci-input-watch with jj, git, gh, ci, nix and notify-send replaced by stubs
# that log each call:
#   nu --no-config-file tests/ci-input-watch.nu tools/ci-input-watch.nu

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
  let tmp = (mktemp --directory)
  mut failures = []

  # Load the exported helpers from a copy without `main`, which `use` would
  # otherwise turn into a command named after the file.
  let module = ($tmp | path join watch.nu)
  open --raw $script | lines | take until {|line| $line starts-with "def main" } | str join "\n" | save $module
  let helper = {|code| nu --no-config-file -c $"use ($module) *; ($code) | to nuon" | from nuon }

  let listing = ([
    "aaa\trefs/tags/2026.10.19.9"
    "bbb\trefs/tags/2026.10.19.10"
    "ccc\trefs/tags/2026.10.2.3"
    "ddd\trefs/tags/v1"
    "eee\trefs/tags/2026.10.18.1"
    "fff\trefs/tags/2026.10.18.1^{}"
  ] | str join "\n")
  let tags = (do $helper $"($listing | to nuon) | parse-tags")
  $failures = ($failures | append (expect "parse-tags takes an annotated tag's commit" ($tags | where tag == "2026.10.18.1" | get commit) [fff]))
  $failures = ($failures | append (expect "latest-release orders release numbers numerically" (do $helper $"($tags | to nuon) | latest-release") { commit: bbb, tag: "2026.10.19.10" }))
  $failures = ($failures | append (expect "latest-release without releases" (do $helper "[{commit: a, tag: v1}] | latest-release") null))
  $failures = ($failures | append (expect "bump-due on ahead and diverged" ([ahead diverged identical behind] | each {|s| do $helper $"bump-due ($s)" }) [true true false false]))

  # The whole check against a repository of stubs.
  let repo = ($tmp | path join dotfiles)
  let bin = ($tmp | path join bin)
  let calls = ($tmp | path join calls)
  let notes = ($tmp | path join notifications)
  mkdir $repo $bin
  { root: root, nodes: { root: { inputs: { ci: ci_2 } }, ci_2: { locked: { rev: pinned } } } } | to json | save ($tmp | path join lock.json)
  "bbb\trefs/tags/2026.10.19.10\n" | save ($tmp | path join tags)
  let stub = {|name, body| $"#!/bin/sh\necho \"($name) $*\" >> ($calls)\n($body)\n" | save ($bin | path join $name) }
  do $stub jj $"case \"$1\" in\n  file\) cat ($tmp)/lock.json ;;\n  diff\) printf '%s' \"$DIFF\" ;;\nesac"
  do $stub git $"cat ($tmp)/tags"
  do $stub gh "echo \"$STATUS\""
  do $stub nix ""
  do $stub ci $"case \"$1\" in\n  start\) mkdir -p ($repo)/.jj-workspaces/$2 ;;\n  dispatch\) if [ -n \"$FAIL\" ]; then echo 'Error: push rejected' >&2; exit 1; fi ;;\nesac"
  $"#!/bin/sh\nprintf '%s|%s\\n' \"$3\" \"$4\" >> ($notes)\n" | save ($bin | path join notify-send)
  ^chmod +x ...(glob ($bin | path join '*'))

  let check = {|status, diff, fail|
    if ($calls | path exists) { rm $calls }
    if ($notes | path exists) { rm $notes }
    with-env {
      PATH: ($env.PATH | prepend $bin)
      CI_INPUT_WATCH_REPO: $repo
      CI_INPUT_WATCH_NOTIFY: ($bin | path join notify-send)
      STATUS: $status
      DIFF: $diff
      FAIL: $fail
    } { ^nu --no-config-file $script check | complete }
  }
  let ci_calls = {|| if ($calls | path exists) { open $calls | lines | where $it starts-with "ci " } else { [] } }
  let summaries = {|| if ($notes | path exists) { open $notes | lines | each { split row '|' | first } } else { [] } }
  let open = ($repo | path join .jj-workspaces ci-input-update)

  let run = (do $check identical "" "")
  $failures = ($failures | append (expect "an up-to-date pin exits cleanly" $run.exit_code 0))
  $failures = ($failures | append (expect "an up-to-date pin opens nothing" (do $ci_calls) []))

  let run = (do $check ahead "flake.lock" "")
  $failures = ($failures | append (expect "a newer release exits cleanly" $run.exit_code 0))
  $failures = ($failures | append (expect "a newer release is dispatched, not landed" (do $ci_calls) [
    "ci start ci-input-update"
    "ci new -m Update the ci input to 2026.10.19.10"
    "ci impact set behavior"
    "ci dispatch"
  ]))
  $failures = ($failures | append (expect "a dispatched bump notifies" (do $summaries) ["ci 2026.10.19.10 is ready to land"]))

  do $check ahead "flake.lock" "" | ignore
  $failures = ($failures | append (expect "an open bump is left alone" (do $ci_calls) []))
  rm --recursive $open

  let run = (do $check ahead "" "")
  $failures = ($failures | append (expect "an empty update cancels the topic" ((do $ci_calls) | last) "ci cancel"))
  $failures = ($failures | append (expect "an empty update stays quiet" (do $summaries) []))
  rm --recursive $open

  let run = (do $check ahead "flake.lock" "1")
  $failures = ($failures | append (expect "a failed dispatch fails the run" ($run.exit_code != 0) true))
  $failures = ($failures | append (expect "a failed dispatch notifies" (do $summaries) ["ci-input-watch: bump to 2026.10.19.10 failed"]))
  $failures = ($failures | append (expect "a failed dispatch keeps its workspace" ($open | path exists) true))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) ci-input-watch checks failed: ($failures | str join ', ')" }
  }
}
