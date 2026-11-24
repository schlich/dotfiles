# Unit checks for deploy/system-switch.nu's step tracker, journal parsers,
# and structured summary builder/formatter:
#   nu --no-config-file tests/system-switch.nu deploy/system-switch.nu

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def run-probe [script: path, expr: string] {
  let result = (^$nu.current-exe --no-config-file -c $"source '($script)'; ($expr) | to json --raw" | complete)
  if $result.exit_code != 0 {
    error make --unspanned { msg: $"probe failed: ($result.stderr)" }
  }
  $result.stdout | from json
}

def main [script: path] {
  let script = ($script | path expand)
  mut failures = []

  # 1. Duration & short-rev helpers
  let helpers = (run-probe $script '{
    d0: (format-duration 0sec)
    dneg: (format-duration (-3sec))
    d74: (format-duration 74500ms)
    rfull: (short-rev "f9aeecfe4327c51423caa423049e97b41dcbaa12")
    rshort: (short-rev "abc")
    rnull: (short-rev null)
  }')
  $failures = ($failures | append (expect "format-duration rounds to whole seconds and clamps negatives" $helpers {
    d0: "0sec"
    dneg: "0sec"
    d74: "1min 14sec"
    rfull: "f9aeecfe4327"
    rshort: "abc"
    rnull: ""
  }))

  # 2. Nix build tally & build-detail
  let build = (run-probe $script r#'
    [
      "these 2 derivations will be built:"
      "these 3 paths will be fetched (1.00 MiB download):"
      "building '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home-manager-generation.drv'..."
      "copying path '/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-foo'..."
      "copying path '/nix/store/cccccccccccccccccccccccccccccccc-bar'..."
    ]
    | reduce --fold { builds: 0, fetches: 0, built: 0, fetched: 0, current: "" } {|line, acc| tally $acc $line }
    | do {|b| { build: $b, report: (build-report $b), detail: (build-detail $b) } } $in
  '#)
  $failures = ($failures | append (expect "tally counts builds, fetches, and current derivation" $build.build {
    builds: 2
    fetches: 3
    built: 1
    fetched: 2
    current: "home-manager-generation"
  }))
  $failures = ($failures | append (expect "build-report computes percentage and compact message" $build.report {
    state: "working"
    id: "switch/build"
    app: "nixos-switch-main"
    msg: "build 1/2: home-manager-generation; fetched 2/3"
    progress: 60
  }))
  $failures = ($failures | append (expect "build-detail summarizes built and fetched counts" $build.detail "1 built, 2 fetched"))

  # 3. Step tracker across a realistic status.jsonl run
  let tracked = (run-probe $script '
    let reports = [
      { time: "2026-11-24T08:03:09-06:00", state: "working", id: "switch", msg: "Switching homelab to main at f9aeecfe4327: Merge branch t3-jobs-view" }
      { time: "2026-11-24T08:03:09-06:00", state: "working", id: "switch/evaluate", msg: "Evaluating homelab" }
      { time: "2026-11-24T08:04:23-06:00", state: "done", id: "switch/evaluate", msg: "Evaluated homelab-26.11-abc" }
      { time: "2026-11-24T08:04:23-06:00", state: "working", id: "switch/build", msg: "Building the closure with one job and two cores, 341G free on /nix" }
      { time: "2026-11-24T08:05:10-06:00", state: "done", id: "switch/build", msg: "Built /nix/store/0xjm6dfvwbkla9angz1iscvg536ccljh-nixos-system" }
      { time: "2026-11-24T08:05:10-06:00", state: "working", id: "switch/preview", msg: "Previewing service changes" }
      { time: "2026-11-24T08:05:11-06:00", state: "done", id: "switch/preview", msg: "Previewed service changes: 1 units to settle" }
      { time: "2026-11-24T08:05:11-06:00", state: "working", id: "switch/watch", msg: "Waiting for 1 units to settle" }
      { time: "2026-11-24T08:05:11-06:00", state: "working", id: "switch/watch", msg: "Waiting for 1 units to settle" }
      { time: "2026-11-24T08:05:12-06:00", state: "working", id: "switch/watch", msg: "1 touched units settled; running probes" }
      { time: "2026-11-24T08:05:13-06:00", state: "done", id: "switch/watch", msg: "Settled after 2s" }
      { time: "2026-11-24T08:05:13-06:00", state: "done", id: "switch", msg: "Deployed main at f9aeecfe4327 on homelab" }
    ]
    let b = { builds: 10, fetches: 0, built: 10, fetched: 0, current: "" }
    mut t = (empty-tracker)
    mut lines = []
    for r in $reports {
      let res = (record-step $t $r $b)
      $t = $res.tracker
      if $res.line != null { $lines = ($lines | append ($res.line | ansi strip)) }
    }
    { subject: $t.subject, steps: $t.steps, lines: $lines }
  ')
  $failures = ($failures | append (expect "record-step extracts commit subject" $tracked.subject "Merge branch t3-jobs-view"))
  $failures = ($failures | append (expect "record-step builds compact step table" $tracked.steps [
    { step: "evaluate", state: "done", took: "1min 14sec", detail: "" }
    { step: "build", state: "done", took: "47sec", detail: "10 built" }
    { step: "preview", state: "done", took: "1sec", detail: "1 unit" }
    { step: "watch", state: "done", took: "2sec", detail: "" }
  ]))
  $failures = ($failures | append (expect "record-step deduplicates repeated working messages and omits redundant switch done line" $tracked.lines [
    "▶ homelab @ f9aeecfe4327: Merge branch t3-jobs-view"
    "▶ evaluate"
    "✓ evaluate (1min 14sec)"
    "▶ build: 341G free on /nix"
    "✓ build (47sec): 10 built"
    "▶ preview"
    "✓ preview (1sec): 1 unit"
    "▶ watch: Waiting for 1 units to settle"
    "  · watch: 1 touched units settled; running probes"
    "✓ watch (2sec)"
  ]))

  # 4. Closure diff & touched units & failed units parsers
  let parsed = (run-probe $script '
    let journal = [
      "would restart the following units: home-manager-schlich.service, nixbot.service"
      "would reload the following units: nixbot.service, sshd.service"
      "package changes from the running system:"
      "<<< /nix/store/old-nixos-system"
      ">>> /nix/store/new-nixos-system"
      "CHANGED (2)"
      "[U.] nixos-system-homelab-homelab 26.11-a -> 26.11-b"
      "[U.] nushell 0.116.0 -> 0.117.0"
      "ADDED (2)"
      "[A.] job-stream <none>"
      "[A.] ripgrep 14.1.1"
      "REMOVED (1)"
      "[R.] watch-project-job <none>"
      "PATHS: 2087 -> 2088 (+23, -22)"
      "SIZE: 14.3 GiB -> 14.3 GiB (+11.0 KiB)"
      "NOTE: 2 hidden (--full to show)"
      "setting up /etc..."
    ]
    {
      units: (parse-touched-units $journal)
      diff: (parse-closure-diff $journal)
      no_diff: (parse-closure-diff ["That configuration is already active; no generation created."])
      failed: (parse-failed-units "foo.service loaded failed failed Foo\nbar.timer   loaded failed failed Bar\n")
      clean_failed: (parse-failed-units "")
    }
  ')
  $failures = ($failures | append (expect "parse-touched-units deduplicates units" $parsed.units [
    "home-manager-schlich.service"
    "nixbot.service"
    "sshd.service"
  ]))
  $failures = ($failures | append (expect "parse-closure-diff extracts structured dix changes and skips nixos-system-*" $parsed.diff {
    paths: "2087 -> 2088 (+23, -22)"
    size: "14.3 GiB -> 14.3 GiB (+11.0 KiB)"
    changed: ["nushell 0.116.0 -> 0.117.0"]
    added: ["job-stream", "ripgrep 14.1.1"]
    removed: ["watch-project-job"]
    note: "2 hidden (--full to show)"
  }))
  $failures = ($failures | append (expect "parse-closure-diff returns null when no diff ran" $parsed.no_diff null))
  $failures = ($failures | append (expect "parse-failed-units extracts unit names" $parsed.failed ["foo.service" "bar.timer"]))
  $failures = ($failures | append (expect "parse-failed-units returns empty list when none failed" $parsed.clean_failed []))

  # 5. Summary formatting (deployed vs unchanged vs capped lists)
  let formatted = (run-probe $script '
    let unchanged = (build-summary {
      host: "homelab"
      outcome: "active"
      rev: "f9aeecfe4327c51423caa423049e97b41dcbaa12"
      subject: "Already active commit"
      generation: 166
      took: "42sec"
      steps: [{ step: "evaluate", state: "done", took: "42sec", detail: "" }]
      changes: null
      units: []
      home: { status: "unchanged", name: "schlich@asus", generation: 42 }
      failed_units: []
      report: ""
      toplevel: "/nix/store/xyz-nixos-system"
      at: "2026-11-24T09:00:00-06:00"
    } | format-summary $in)
    let capped = (join-cap ["a" "b" "c" "d" "e"] 3)
    let homes = {
      activated: (format-home { status: "activated", generation: 42, took: "12sec" })
      embedded: (format-home { status: "embedded", generation: 13 })
      none: (format-home { status: "none" })
      failed: (format-home { status: "failed", error: "collision" })
    }
    { unchanged: $unchanged, capped: $capped, homes: $homes }
  ')
  $failures = ($failures | append (expect "format-summary omits empty optional fields and empty detail column" $formatted.unchanged {
    host: "homelab"
    outcome: "active"
    rev: "f9aeecfe4327 — Already active commit"
    generation: 166
    took: "42sec"
    steps: [{ step: "evaluate", state: "done", took: "42sec" }]
    home: "already active (gen 42)"
  }))
  $failures = ($failures | append (expect "join-cap summarizes overflow cleanly" $formatted.capped "a, b, c (+2 more)"))
  $failures = ($failures | append (expect "format-home formats each home state concisely" $formatted.homes {
    activated: "activated (gen 42, 12sec)"
    embedded: "embedded in system (gen 13)"
    none: "none in main"
    failed: "failed: collision"
  }))

  # 6. Error step handling, multi-block closure diff, and failure summary formatting
  let edge = (run-probe $script '
    let b = { builds: 2, fetches: 0, built: 1, fetched: 0, current: "foo" }
    mut t = (empty-tracker)
    mut lines = []
    for r in [
      { time: "2026-11-24T08:00:00-06:00", state: "working", id: "switch", msg: "Switching homelab to main at deadbeef1234: broken" }
      { time: "2026-11-24T08:00:01-06:00", state: "working", id: "switch/build", msg: "Building the closure" }
      { time: "2026-11-24T08:00:10-06:00", state: "error", id: "switch/build", msg: "error: Cannot build /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo.drv" }
      { time: "2026-11-24T08:00:11-06:00", state: "error", id: "switch", msg: "Rejected main at deadbeef1234" }
    ] {
      let res = (record-step $t $r $b)
      $t = $res.tracker
      if $res.line != null { $lines = ($lines | append ($res.line | ansi strip)) }
    }
    let two_diffs = (parse-closure-diff [
      "package changes from the running system:"
      "ADDED (1)"
      "[A.] old-pkg <none>"
      "PATHS: 100 -> 101 (+1, -0)"
      "SIZE: 1 GiB -> 1 GiB (+1 MiB)"
      "setting up /etc..."
      "package changes from the running system:"
      "REMOVED (1)"
      "[R.] old-pkg <none>"
      "PATHS: 101 -> 100 (+0, -1)"
      "SIZE: 1 GiB -> 1 GiB (-1 MiB)"
    ])
    let failed_summary = (build-summary {
      host: "homelab"
      outcome: "rejected"
      rev: "deadbeef1234567890"
      subject: "broken"
      generation: 166
      took: "11sec"
      steps: $t.steps
      changes: null
      units: []
      home: null
      failed_units: ["foo.service"]
      report: "/var/lib/nixos-switch-main/reports/1.md"
      toplevel: ""
      at: "2026-11-24T08:00:11-06:00"
    } | format-summary $in)
    { lines: $lines, two_diffs: $two_diffs, failed_summary: $failed_summary }
  ')
  $failures = ($failures | append (expect "record-step strips store hash on error and prints switch error" $edge.lines [
    "▶ homelab @ deadbeef1234: broken"
    "▶ build"
    "✗ build (9sec): error: Cannot build foo.drv"
    "✗ switch (11sec): Rejected main at deadbeef1234"
  ]))
  $failures = ($failures | append (expect "parse-closure-diff keeps latest diff block when multiple appear" $edge.two_diffs {
    paths: "101 -> 100 (+0, -1)"
    size: "1 GiB -> 1 GiB (-1 MiB)"
    changed: []
    added: []
    removed: ["old-pkg"]
  }))
  $failures = ($failures | append (expect "format-summary keeps detail, failed_units, and report on failure" $edge.failed_summary {
    host: "homelab"
    outcome: "rejected"
    rev: "deadbeef1234 — broken"
    generation: 166
    took: "11sec"
    steps: [{ step: "build", state: "error", took: "9sec", detail: "error: Cannot build foo.drv" }]
    failed_units: "foo.service"
    report: "/var/lib/nixos-switch-main/reports/1.md"
  }))

  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) system-switch checks failed: ($failures | str join ', ')" }
  }
  print "All system-switch checks passed."
}
