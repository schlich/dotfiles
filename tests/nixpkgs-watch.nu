# nixpkgs-watch against npr's real output format, with npr and notify-send
# replaced by stubs:
#   nu --no-config-file tests/nixpkgs-watch.nu tools/nixpkgs-watch.nu

# One PR block as npr renders it: ANSI colours and an OSC 8 link on the number.
def npr-pr [title: string, status: string, number: int, reached?: string] {
  let link = $"\e]8;;https://github.com/NixOS/nixpkgs/pull/($number)\e\\#($number)\e]8;;\e\\"
  let head = $"(ansi attr_bold)PR:(ansi reset) (ansi cyan)($title)(ansi reset) \((ansi green)($status)(ansi reset)\) (ansi attr_dimmed)($link)(ansi reset)"
  if $reached == null { $head } else {
    $"($head)\n   (ansi attr_dimmed)└─(ansi reset) Reachable in: ($reached)"
  }
}

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

  let output = ([
    "Searching for opencode..."
    (npr-pr "opencode: 1.19.0 -> 2.0.16" merged 501 $"(ansi light_green)nixpkgs-unstable(ansi reset), (ansi light_green)nixos-unstable-small(ansi reset)")
    (npr-pr "[Backport release-26.05] opencode: 1.18.0 -> 1.19.0" merged 502 $"(ansi yellow)None(ansi reset) \(pending Hydra/Mirror\)")
    (npr-pr "opencode: 2.0.16 -> 2.1.0" open 503)
    (npr-pr "opencode-desktop: init at 2.0.16" closed 504)
    (npr-pr "treewide: mention opencode" merged 505 $"(ansi yellow)Unknown(ansi reset)")
  ] | str join "\n")

  let parsed = (nu --no-config-file -c $"use ($module) *; ($output | to nuon) | parse-npr | to nuon" | from nuon)
  $failures = ($failures | append (expect "parse-npr reads each PR block" $parsed [
    { title: "opencode: 1.19.0 -> 2.0.16", status: merged, number: 501, reached: [nixpkgs-unstable nixos-unstable-small] }
    { title: "[Backport release-26.05] opencode: 1.18.0 -> 1.19.0", status: merged, number: 502, reached: [] }
    { title: "opencode: 2.0.16 -> 2.1.0", status: open, number: 503, reached: [] }
    { title: "opencode-desktop: init at 2.0.16", status: closed, number: 504, reached: [] }
    { title: "treewide: mention opencode", status: merged, number: 505, reached: [] }
  ]))

  let own = (nu --no-config-file -c $"use ($module) *; ($parsed | to nuon) | own-prs opencode | to nuon" | from nuon)
  $failures = ($failures | append (expect "own-prs keeps the package's own PRs" ($own | select number landed) [
    { number: 501, landed: true }
    { number: 503, landed: false }
  ]))

  let entry = { package: opencode, version: "2.0.16", nixpkgs: "2.0.16", ready: true, reason: "drop the opencode input" }
  let events = {|seen|
    nu --no-config-file -c $"use ($module) *; events ($entry | to nuon) ($own | to nuon) ($seen | to nuon) | get kind | to nuon" | from nuon
  }
  $failures = ($failures | append (expect "events on first sight" (do $events []) [landed opened ready]))
  let remembered = (nu --no-config-file -c $"use ($module) *; remember ($entry | to nuon) ($own | to nuon) | to nuon" | from nuon)
  $failures = ($failures | append (expect "events after remembering" (do $events $remembered) []))
  let before_landing = ($remembered | update landed {|row| if $row.key == "opencode#501" { false } else { $row.landed } })
  $failures = ($failures | append (expect "events when a PR reaches unstable" (do $events $before_landing) [landed]))

  # The whole check, with stubbed npr and notify-send.
  let fixture = ($tmp | path join npr-output)
  let notes = ($tmp | path join notifications)
  let npr = ($tmp | path join npr)
  let notify = ($tmp | path join notify-send)
  $"#!/bin/sh\nif [ -n \"$FAIL\" ]; then echo 'Error: gh is not authenticated' >&2; exit 1; fi\ncat ($fixture)\n" | save $npr
  $"#!/bin/sh\nprintf '%s|%s\\n' \"$3\" \"$4\" >> ($notes)\n" | save $notify
  ^chmod +x $npr $notify
  let status = ($tmp | path join status.json)
  { opencode: ($entry | update ready false | update nixpkgs "1.19.0") } | to json | save $status
  let check = {|fail|
    with-env {
      HOME: $tmp
      XDG_STATE_HOME: ($tmp | path join state)
      NIXPKGS_WATCH_STATUS: $status
      NIXPKGS_WATCH_NPR: $npr
      NIXPKGS_WATCH_NOTIFY: $notify
      FAIL: $fail
    } { ^nu --no-config-file $script check --notify | complete }
  }
  let summaries = {|| if ($notes | path exists) { open $notes | lines | each { split row '|' | first } } else { [] } }

  [(npr-pr "opencode: 2.0.16 -> 2.1.0" open 503)] | str join "\n" | save --force $fixture
  let run = (do $check "")
  $failures = ($failures | append (expect "first check exits cleanly" $run.exit_code 0))
  $failures = ($failures | append (expect "first check sends one summary" (do $summaries) ["nixpkgs-watch is on"]))

  [(npr-pr "opencode: 2.0.16 -> 2.1.0" merged 503 "nixos-unstable")] | str join "\n" | save --force $fixture
  do $check "" | ignore
  $failures = ($failures | append (expect "a PR reaching unstable notifies" (do $summaries | skip 1) ["nixpkgs: opencode"]))
  do $check "" | ignore
  $failures = ($failures | append (expect "an unchanged PR stays quiet" (do $summaries | length) 2))

  do $check "1" | ignore
  do $check "1" | ignore
  $failures = ($failures | append (expect "a lasting npr failure notifies once" (do $summaries | skip 2) ["nixpkgs-watch: npr failed for opencode"]))
  let seen = (open ($tmp | path join state nixpkgs-watch seen.json) | get key)
  $failures = ($failures | append (expect "a failed search keeps what was seen" $seen ["opencode#503"]))
  let report = (open ($tmp | path join state nixpkgs-watch report.json))
  $failures = ($failures | append (expect "the report records the failure" ($report.entries.0.error) "Error: gh is not authenticated"))

  let shown = (with-env { HOME: $tmp, XDG_STATE_HOME: ($tmp | path join state) } { ^nu --no-config-file $script | complete })
  $failures = ($failures | append (expect "the report prints" ($shown.exit_code == 0 and ($shown.stdout | str contains opencode)) true))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) nixpkgs-watch checks failed: ($failures | str join ', ')" }
  }
}
