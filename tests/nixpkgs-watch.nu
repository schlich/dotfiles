# nixpkgs-watch against npr's real output format, with npr, notify-send, and
# jev replaced by stubs:
#   nu --no-config-file tests/nixpkgs-watch.nu tools/nixpkgs-watch.nu jev/questions.nuon

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

def main [script: path, questions: path] {
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

  # With jev, the pull requests that only mention the package are judged.
  # The stub records each request and calls a title that renames opencode
  # related; it fails while JEV_FAIL is set.
  let calls = ($tmp | path join jev-calls)
  let jev = ($tmp | path join jev)
  [
    "#!/bin/sh"
    "if [ -n \"$JEV_FAIL\" ]; then echo 'Jev request failed with HTTP 503' >&2; exit 1; fi"
    "req=$(cat)"
    $"printf '%s\\n' \"$req\" >> ($calls)"
    "case \"$req\" in"
    "  *'\"title\":\"treewide: rename'*) p=0.9 ;;"
    "  *) p=0.2 ;;"
    "esac"
    "printf '{\"answers\":{\"bears_on_workaround\":{\"type\":\"noul\",\"noul\":%s}}}' \"$p\""
  ] | str join "\n" | save $jev
  ^chmod +x $jev
  let judged_check = {|state, fail|
    with-env {
      HOME: $tmp
      XDG_STATE_HOME: $state
      NIXPKGS_WATCH_STATUS: $status
      NIXPKGS_WATCH_NPR: $npr
      NIXPKGS_WATCH_NOTIFY: $notify
      NIXPKGS_WATCH_JEV: $jev
      NIXPKGS_WATCH_QUESTIONS: ($questions | path expand)
      FAIL: ""
      JEV_FAIL: $fail
    } { ^nu --no-config-file $script check --notify | complete }
  }
  let jev_calls = {|| if ($calls | path exists) { open --raw $calls | lines | each { from json } } else { [] } }
  [
    (npr-pr "opencode: 2.0.16 -> 2.1.0" open 503)
    (npr-pr "opencode-desktop: init at 2.0.16" open 504)
    (npr-pr "[Backport release-26.05] python3Packages.foo: rename opencode" merged 505 "nixos-unstable")
    (npr-pr "treewide: rename opencode-unwrapped to opencode" merged 506 "nixpkgs-unstable")
  ] | str join "\n" | save --force $fixture
  rm --force $notes

  let jev_state = ($tmp | path join jev-state)
  let run = (do $judged_check $jev_state "")
  $failures = ($failures | append (expect "a check with jev exits cleanly" $run.exit_code 0))
  $failures = ($failures | append (expect "jev judges other PRs but not backports" (do $jev_calls | get state.pr.title) ["opencode-desktop: init at 2.0.16" "treewide: rename opencode-unwrapped to opencode"]))
  $failures = ($failures | append (expect "jev sees the PR and the workaround" (do $jev_calls | get 0.state | columns | sort) [pr workaround]))
  let report = (open ($jev_state | path join nixpkgs-watch report.json))
  $failures = ($failures | append (expect "the report lists related PRs" ($report.entries.0.related) [506]))
  $failures = ($failures | append (expect "own PRs stay as they were" ($report.entries.0.open) [503]))

  do $judged_check $jev_state "" | ignore
  $failures = ($failures | append (expect "verdicts are reused on the next run" (do $jev_calls | length) 2))
  let seen = (open ($jev_state | path join nixpkgs-watch seen.json))
  $failures = ($failures | append (expect "the seen list keeps each verdict" ($seen | where key in ["opencode#504" "opencode#506"] | get related) [0.2 0.9]))

  # A failed jev keeps nothing, so the pull request is asked about again.
  let retry_state = ($tmp | path join retry-state)
  rm --force $calls
  let failed = (do $judged_check $retry_state "1")
  $failures = ($failures | append (expect "a jev failure does not fail the check" $failed.exit_code 0))
  $failures = ($failures | append (expect "a jev failure reports nothing related" (open ($retry_state | path join nixpkgs-watch report.json) | get entries.0.related) []))
  do $judged_check $retry_state "" | ignore
  $failures = ($failures | append (expect "unjudged PRs are asked again" (do $jev_calls | length) 2))
  rm --force $notes
  do $judged_check $retry_state "" | ignore
  let retried = (with-env { HOME: $tmp, XDG_STATE_HOME: $retry_state } { open ($retry_state | path join nixpkgs-watch report.json) })
  $failures = ($failures | append (expect "the retried run finds the related PR" ($retried.entries.0.related) [506]))

  # Coverage: which lines are workarounds, and what covers them.
  let call = {|code| nu --no-config-file -c $"use ($module) *; ($code) | to nuon" | from nuon }
  let nix = ([
    "{ inputs, pkgs }:"
    "let"
    "  a = inputs.foo.packages.${pkgs.system}.default;"
    "  # inputs.commented.packages.x"
    "  b = pkgs.callPackage \"${inputs.bar}/nix/pkg.nix\" { };"
    "  c = pkgs.hello.overrideAttrs { doCheck = false; };"
    "  d = inputs.nixpkgs.legacyPackages.x.hello;"
    "in [ a b c d ]"
  ] | str join "\n")
  $failures = ($failures | append (expect "sites finds inputs, sources, and overrides" (do $call $"($nix | to nuon) | sites | select line input") [
    { line: 3, input: foo }
    { line: 5, input: bar }
    { line: 6, input: null }
  ]))
  $failures = ($failures | append (expect "named-for strips -package and reads directories" (do $call "[modules/programs/hokum-package.nix modules/tooling/ai/jj-mcp/default.nix tools/foo/package.nix x/sudoplz.nix] | each { named-for $in }") [hokum jj-mcp foo sudoplz]))
  let declared = { entries: { foo: { package: foo, input: foo } }, exempt: { bar: "the user's own" } }
  let uncovered = {|text file| do $call $"($text | to nuon) | uncovered ($file | to nuon) ($declared | to nuon) | each {|s| $s.line | default none }" }
  $failures = ($failures | append (expect "an unwatched override is uncovered" (do $uncovered $nix modules/x.nix) [6]))
  $failures = ($failures | append (expect "an entry named for the file covers it" (do $uncovered $nix modules/foo-package.nix) []))
  $failures = ($failures | append (expect "a comment naming an entry covers it" (do $uncovered $"# nixpkgs-watch: foo\n($nix)" modules/x.nix) []))
  $failures = ($failures | append (expect "a comment naming no entry does not" (do $uncovered $"# nixpkgs-watch: baz\n($nix)" modules/x.nix) [7 none]))
  $failures = ($failures | append (expect "not a workaround covers it" (do $uncovered $"# nixpkgs-watch: not a workaround: local\n($nix)" modules/x.nix) []))
  let declaring = $"($nix)\n{ dotfiles.nixpkgsWatch.hello.reason = \"r\"; }"
  $failures = ($failures | append (expect "a declaration covers the file" (do $uncovered $declaring modules/x.nix) []))
  let no_foo = { entries: {}, exempt: { bar: "the user's own" } }
  $failures = ($failures | append (expect "an input needs an entry even where one is declared" (do $call $"($declaring | to nuon) | uncovered modules/x.nix ($no_foo | to nuon) | get input") [foo]))

  let coverage_dir = ($tmp | path join repo)
  mkdir ($coverage_dir | path join modules)
  $nix | save ($coverage_dir | path join modules x.nix)
  $declared | to json | save ($tmp | path join declared.json)
  let coverage = {|| ^nu --no-config-file $script coverage $coverage_dir ($tmp | path join declared.json) | complete }
  let run = (do $coverage)
  $failures = ($failures | append (expect "coverage fails on an uncovered workaround" [$run.exit_code ($run.stdout | str contains "modules/x.nix:6")] [1 true]))
  $"# nixpkgs-watch: not a workaround: a test\n($nix)" | save --force ($coverage_dir | path join modules x.nix)
  $failures = ($failures | append (expect "coverage passes once it is covered" (do $coverage | get exit_code) 0))

  # Upstream lookups.
  let urls = [https://github.com/o/r/pull/12 https://github.com/o/r/commit/abc123 https://example.com/x]
  $failures = ($failures | append (expect "parse-fix reads pull requests and commits" (do $call $"($urls | to nuon) | each {|url| { fix: \(parse-fix $url\) } }") [
    { fix: { repo: o/r, kind: pull, id: "12" } }
    { fix: { repo: o/r, kind: commit, id: abc123 } }
    { fix: null }
  ]))
  let forked = { package: codex, fix: "https://github.com/o/codex/commit/abc", nixpkgs: "0.169.0", reason: "drop the fork" }
  $failures = ($failures | append (expect "a fork's unreleased commit stays quiet" (do $call $"fix-events ($forked | to nuon) {state: unreleased} [] | length") 0))
  $failures = ($failures | append (expect "and its release is the way out" (do $call $"fix-events ($forked | to nuon) {state: released} [{key: 'codex!fix', status: unreleased}] | get kind") [ready]))
  let flake = "{\n  nixConfig = {\n    extra-substituters = [\n      \"https://a.cachix.org\"\n      \"https://cache.nixos.org/\"\n    ];\n    extra-trusted-public-keys = [ \"a.cachix.org-1:x\" ];\n  };\n  nixConfig.substituters = \"https://b.example https://c.example\";\n}"
  $failures = ($failures | append (expect "substituters-in reads nixConfig" (do $call $"($flake | to nuon) | substituters-in") [https://a.cachix.org https://cache.nixos.org https://b.example https://c.example]))
  let boards = [
    [title existing];
    ["opencode-desktop: use nixpkgs' opencode-desktop" ["opencode: use nixpkgs' opencode and opencode-desktop"]]
    ["opencode: use nixpkgs' opencode" ["opencode-desktop: use nixpkgs' opencode-desktop"]]
    ["fh: use nixpkgs' fh" ["fh, jj-starship: use nixpkgs' cached builds"]]
    ["fh: drop the override, fixed upstream" ["fh, jj-starship: use nixpkgs' cached builds"]]
  ]
  $failures = ($failures | append (expect "on-board matches the package and the way out" (do $call $"($boards | to nuon) | each {|c| on-board $c.title $c.existing }") [true false true false]))

  # The whole check against stubbed gh, nix, curl, and luvus: hex overrides
  # an input whose upstream fix and cached build the check finds; tool is a
  # local build whose upstream appears on FlakeHub and gains a flake.nix.
  let bin = ($tmp | path join bin)
  mkdir $bin
  let src = ($tmp | path join hex-src)
  mkdir $src
  "{ nixConfig.extra-substituters = [ \"https://hex.cachix.org\" ]; }" | save ($src | path join flake.nix)
  let board = ($tmp | path join board.json)
  let added = ($tmp | path join added)
  [
    "#!/bin/sh"
    "case \"$2\" in"
    "  repos/anomalyco/hex/pulls/7) echo '{\"state\":\"closed\",\"merged_at\":\"2026-11-01T00:00:00Z\",\"merge_commit_sha\":\"m7\"}' ;;"
    "  repos/anomalyco/hex/compare/m7...v3.4.0) if [ -n \"$RELEASED\" ]; then echo ahead; else echo diverged; fi ;;"
    "  repos/acme/tool/contents/flake.nix) echo flake.nix ;;"
    "  *) echo 'HTTP 404: Not Found' >&2; exit 1 ;;"
    "esac"
  ] | str join "\n" | save ($bin | path join gh)
  [
    "#!/bin/sh"
    "case \"$1\" in"
    "  eval) echo /nix/store/aaaa-hex-3.4.0 ;;"
    $"  flake\) echo '{\"storePath\":\"($src)\"}' ;;"
    "  path-info) [ \"$3\" = https://hex.cachix.org ] ;;"
    "esac"
  ] | str join "\n" | save ($bin | path join nix)
  [
    "#!/bin/sh"
    "for a; do url=$a; done"
    "case \"$url\" in */acme/tool) echo 200 ;; *) echo 404 ;; esac"
  ] | str join "\n" | save ($bin | path join curl)
  [
    "#!/bin/sh"
    "if [ -n \"$LUVUS_FAIL\" ]; then echo 'luvus: server not running' >&2; exit 1; fi"
    $"if [ \"$2\" = list ]; then cat ($board); exit 0; fi"
    $"printf '%s\\n' \"$3\" >> ($added)"
  ] | str join "\n" | save ($bin | path join luvus)
  ^chmod +x ...(glob ($bin | path join '*'))
  { result: { tasks: [{ title: "atuin: use nixpkgs' atuin" }] } } | to json | save $board

  let upstream_status = ($tmp | path join upstream-status.json)
  let common = { version: null, nixpkgs: null, ready: false, fix: null, input: null, attr: default, repo: null, locked: null, rev: null, follows: false, onFlakehub: false, files: [], system: x86_64-linux }
  {
    hex: ($common | merge { name: hex, package: hex, nixpkgs: "3.4.0", reason: "drop the cargoDeps override in hex.nix", fix: "https://github.com/anomalyco/hex/pull/7", input: hex, attr: hex, repo: anomalyco/hex, locked: "github:anomalyco/hex/abc", rev: abc, follows: true, onFlakehub: true, files: [modules/programs/hex.nix] })
    tool: ($common | merge { name: tool, package: tool, version: "1.0", reason: "replace tool-package.nix", repo: acme/tool, files: [modules/tool.nix] })
  } | to json | save $upstream_status
  "" | save --force $fixture
  let upstream_state = ($tmp | path join upstream-state)
  mkdir ($upstream_state | path join nixpkgs-watch)
  [] | to json | save ($upstream_state | path join nixpkgs-watch seen.json)
  let upstream_check = {|state, released, luvus_fail|
    with-env {
      HOME: $tmp
      XDG_STATE_HOME: $state
      NIXPKGS_WATCH_STATUS: $upstream_status
      NIXPKGS_WATCH_NPR: $npr
      NIXPKGS_WATCH_NOTIFY: $notify
      NIXPKGS_WATCH_GH: ($bin | path join gh)
      NIXPKGS_WATCH_NIX: ($bin | path join nix)
      NIXPKGS_WATCH_CURL: ($bin | path join curl)
      NIXPKGS_WATCH_LUVUS: ($bin | path join luvus)
      NIXPKGS_WATCH_REPO: $tmp
      NIXPKGS_WATCH_GATE: "true"
      FAIL: ""
      RELEASED: $released
      LUVUS_FAIL: $luvus_fail
    } { ^nu --no-config-file $script check --notify --queue-tasks | complete }
  }
  let added_titles = {|| if ($added | path exists) { open --raw $added | lines } else { [] } }
  rm --force $notes

  let run = (do $upstream_check $upstream_state "" "1")
  $failures = ($failures | append (expect "an upstream check exits cleanly" $run.exit_code 0))
  let report = (open ($upstream_state | path join nixpkgs-watch report.json))
  $failures = ($failures | append (expect "it reports the fix, the cache, FlakeHub, and the flake" ($report.entries | select package upstream) [
    { package: hex, upstream: ["fix merged" "cached: hex.cachix.org"] }
    { package: tool, upstream: ["on FlakeHub" "has a flake"] }
  ]))
  $failures = ($failures | append (expect "each finding is an event" ($report.events | each { $"($in.package) ($in.kind)" }) ["hex fix-merged" "hex cached" "tool flakehub" "tool flake"]))
  $failures = ($failures | append (expect "a luvus failure queues nothing and notifies" [(do $added_titles) (do $summaries | last)] [[] "nixpkgs-watch could not queue a luvus task"]))

  rm --force $notes
  let run = (do $upstream_check $upstream_state "" "")
  $failures = ($failures | append (expect "a queueing check exits cleanly" $run.exit_code 0))
  $failures = ($failures | append (expect "the next run queues the cached build's task" (do $added_titles) ["hex: substitute upstream's cached build"]))
  $failures = ($failures | append (expect "findings are not repeated" (do $summaries) ["nixpkgs-watch queued a task"]))

  rm --force $notes
  do $upstream_check $upstream_state "1" "" | ignore
  $failures = ($failures | append (expect "a released fix queues its task once" (do $added_titles) ["hex: substitute upstream's cached build" "hex: drop the override, fixed upstream"]))
  $failures = ($failures | append (expect "and notifies that the workaround can go" (do $summaries) ["nixpkgs: hex" "nixpkgs-watch queued a task"]))
  do $upstream_check $upstream_state "1" "" | ignore
  $failures = ($failures | append (expect "a queued task is not queued again" (do $added_titles | length) 2))

  # A task someone already put on the board is recorded, not duplicated.
  let board_state = ($tmp | path join board-state)
  mkdir ($board_state | path join nixpkgs-watch)
  [] | to json | save ($board_state | path join nixpkgs-watch seen.json)
  { result: { tasks: [{ title: "hex: substitute upstream's cached build and drop follows" }] } } | to json | save --force $board
  rm --force $added
  do $upstream_check $board_state "" "" | ignore
  $failures = ($failures | append (expect "a task already on the board is not added" (do $added_titles) []))
  $failures = ($failures | append (expect "and is recorded as done" (open ($board_state | path join nixpkgs-watch tasks.json)) ["hex: substitute upstream's cached build"]))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) nixpkgs-watch checks failed: ($failures | str join ', ')" }
  }
}
