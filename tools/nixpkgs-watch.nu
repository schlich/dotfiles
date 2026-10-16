# Watch nixpkgs for the packages this home works around (dotfiles.nixpkgsWatch
# in modules/home/nixpkgs-watch.nix), so each workaround goes once nixpkgs
# catches up.
#
#   nixpkgs-watch                  the last report
#   nixpkgs-watch check            ask npr now and print what changed
#   nixpkgs-watch check --notify   the same as desktop notifications (the timer)
#
# The wrapper sets NIXPKGS_WATCH_STATUS (each entry with the version the
# locked nixpkgs ships, written at build time), NIXPKGS_WATCH_NPR and
# NIXPKGS_WATCH_NOTIFY.

const channels = [nixpkgs-unstable nixos-unstable]

def state-dir [] {
  $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join nixpkgs-watch
}

# npr prints for people only: colours, OSC 8 links, one "PR:" line per pull
# request and a "Reachable in:" line under each merged one.
export def parse-npr []: string -> list<record> {
  let lines = (
    $in
    | str replace --all --regex '\x1b\]8;;[^\x1b]*\x1b\\' ''
    | ansi strip
    | lines
  )
  mut prs = []
  for line in $lines {
    let pr = ($line | parse --regex '^PR: (?<title>.*) \((?<status>open|closed|merged)\) #(?<number>\d+)\s*$')
    if ($pr | is-not-empty) {
      $prs = ($prs | append ($pr.0 | update number { into int } | insert reached []))
    } else if ($prs | is-not-empty) and ($line =~ 'Reachable in: ') {
      let reached = (
        $line
        | parse --regex 'Reachable in: (?<branches>.*)$'
        | get 0.branches
        | split row ','
        | each { str trim }
        | where {|branch| $branch =~ '^nix(os|pkgs)-' }
      )
      let i = ($prs | length) - 1
      $prs = ($prs | update $i ($prs | get $i | update reached $reached))
    }
  }
  $prs
}

# A package's own pull requests, as nixpkgs titles them ("pkg: 1.0 -> 1.1",
# "pkg: init at 1.0"); npr's search also returns anything that mentions it.
# Backports target release branches, which this flake does not follow.
export def own-prs [package: string]: list<record> -> list<record> {
  where {|pr| $pr.title | str starts-with $"($package):" }
  | each {|pr| $pr | insert landed ($pr.reached | any {|branch| $branch in $channels }) }
}

# What is new since the last run: a pull request opened, one reaching the
# unstable channels, or the locked nixpkgs now shipping what the workaround
# provides.
export def events [entry: record, prs: list<record>, seen: list<record>]: nothing -> list<record> {
  let pr_events = (
    $prs | each {|pr|
      let key = $"($entry.package)#($pr.number)"
      let before = ($seen | where key == $key | get --optional 0)
      if $before == null and $pr.status == "open" {
        { package: $entry.package, kind: opened, text: $"#($pr.number) opened: ($pr.title)" }
      } else if $pr.landed and ($before == null or not $before.landed) {
        { package: $entry.package, kind: landed, text: $"#($pr.number) reached ($pr.reached | where {|b| $b in $channels } | str join ', '): ($pr.title). `nix flake update nixpkgs` picks it up." }
      }
    } | compact
  )
  let ready_key = $"($entry.package)@($entry.nixpkgs)"
  let ready = if $entry.ready and ($seen | where key == $ready_key | is-empty) {
    [{ package: $entry.package, kind: ready, text: $"The locked nixpkgs ships ($entry.package) ($entry.nixpkgs | default 'now'). Remove the workaround: ($entry.reason)" }]
  } else { [] }
  $pr_events | append $ready
}

# The seen list after this run: every pull request's state and each ready
# version, so a change is reported once.
export def remember [entry: record, prs: list<record>]: nothing -> list<record> {
  $prs
  | each {|pr| { key: $"($entry.package)#($pr.number)", status: $pr.status, landed: $pr.landed } }
  | append (if $entry.ready { [{ key: $"($entry.package)@($entry.nixpkgs)", status: ready, landed: true }] } else { [] })
}

def notify [summary: string, body: string] {
  try { ^$env.NIXPKGS_WATCH_NOTIFY --app-name nixpkgs-watch $summary $body } catch { }
}

def show [report: record] {
  print $"Checked ($report.checked | into datetime | date humanize), PRs from the last ($report.days) days."
  let prs = {|numbers| $numbers | each { $"#($in)" } | str join " " }
  print (
    $report.entries
    | each {|entry|
        {
          package: $entry.package
          pinned: ($entry.version | default "-")
          nixpkgs: ($entry.nixpkgs | default "absent")
          "drop workaround": (if $entry.ready { "yes" } else { "" })
          "open PRs": (do $prs $entry.open)
          "in unstable": (do $prs $entry.landed)
          error: ($entry.error | default "")
        }
      }
    | table --index false
  )
  if ($report.events | is-not-empty) {
    print "Since the run before:"
    $report.events | each {|event| print $"  ($event.package): ($event.text)" } | ignore
  }
}

def main [] {
  let report = (state-dir | path join report.json)
  if not ($report | path exists) {
    print "No report yet; run `nixpkgs-watch check`."
    return
  }
  show (open $report)
}

def "main check" [
  --days: int = 30  # how far back npr searches; PRs are tracked from then on
  --notify          # report changes as desktop notifications
] {
  let dir = (state-dir)
  mkdir $dir
  let seen_file = ($dir | path join seen.json)
  let first_run = not ($seen_file | path exists)
  let seen = if $first_run { [] } else { open $seen_file }
  let report_file = ($dir | path join report.json)
  let previous_errors = if ($report_file | path exists) {
    open $report_file | get entries | where error != null | select package error
  } else { [] }

  let results = (
    open $env.NIXPKGS_WATCH_STATUS
    | transpose name entry
    | each {|item|
        let entry = $item.entry
        let run = (^$env.NIXPKGS_WATCH_NPR --days $days $entry.package | complete)
        let prs = if $run.exit_code == 0 { $run.stdout | parse-npr | own-prs $entry.package } else { [] }
        {
          entry: $entry
          prs: $prs
          error: (if $run.exit_code != 0 { $run.stderr | str trim | lines | last })
          events: (if $run.exit_code == 0 { events $entry $prs $seen } else { [] })
        }
      }
  )

  # A failed search keeps what was seen, so its changes still show next time.
  let failed = ($results | where error != null | get entry.package)
  let kept = ($seen | where {|row| ($row.key | split row --regex '[#@]' | first) in $failed })
  $results | where error == null | each {|r| remember $r.entry $r.prs } | flatten | append $kept | save --force $seen_file

  let events = ($results | get events | flatten)
  let report = {
    checked: (date now | format date "%+")
    days: $days
    entries: ($results | each {|r|
      $r.entry | select package version nixpkgs ready reason | merge {
        open: ($r.prs | where status == open | get number)
        landed: ($r.prs | where landed | get number)
        error: $r.error
      }
    })
    events: $events
  }
  $report | save --force $report_file

  if $notify {
    if $first_run {
      let open = ($report.entries | get open | flatten | length)
      notify "nixpkgs-watch is on" $"Watching ($report.entries | length) packages; ($open) pull requests open. Run `nixpkgs-watch` for the report."
    } else {
      for event in $events { notify $"nixpkgs: ($event.package)" $event.text }
    }
    # A failure that persists is reported once, not every day.
    for r in ($results | where error != null) {
      if ($previous_errors | where package == $r.entry.package and error == $r.error | is-empty) {
        notify $"nixpkgs-watch: npr failed for ($r.entry.package)" $r.error
      }
    }
  } else {
    show $report
  }
}
