# Watch nixpkgs for the packages this home works around (dotfiles.nixpkgsWatch
# in modules/home/nixpkgs-watch.nix), so each workaround goes once nixpkgs
# catches up.
#
#   nixpkgs-watch                  the last report
#   nixpkgs-watch check            ask npr now and print what changed
#   nixpkgs-watch check --notify   the same as desktop notifications (the timer)
#
# The wrapper sets NIXPKGS_WATCH_STATUS (each entry with the version the
# locked nixpkgs ships, written at build time), NIXPKGS_WATCH_NPR,
# NIXPKGS_WATCH_NOTIFY, and NIXPKGS_WATCH_JEV with NIXPKGS_WATCH_QUESTIONS,
# which let Jev judge the pull requests that only mention a package. Without
# the last two, those are ignored as before.

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

# The rest of npr's results, minus backports: pull requests that mention the
# package without being its own, such as a rename, a treewide change, or a
# dependency's update.
export def other-prs [package: string]: list<record> -> list<record> {
  where {|pr| not ($pr.title | str starts-with $"($package):") and not ($pr.title | str starts-with "[Backport") }
  | each {|pr| $pr | insert landed ($pr.reached | any {|branch| $branch in $channels }) }
}

# Each other pull request with `related`, Jev's probability from its title
# that it bears on the workaround. A verdict in the seen list is reused, so
# each pull request is asked about once; one Jev could not give stays null
# and is asked again next run.
def judge-related [entry: record, prs: list<record>, seen: list<record>]: nothing -> list<record> {
  let config = (open $env.NIXPKGS_WATCH_QUESTIONS).nixpkgs_watch
  $prs | each {|pr|
    let known = ($seen | where key == $"($entry.package)#($pr.number)" | get --optional 0.related)
    let related = if $known != null { $known } else {
      let request = {
        state: { pr: ($pr | select title status), workaround: ($entry | select package reason) }
        questions: $config.questions
      }
      let run = ($request | to json --raw | run-external $env.NIXPKGS_WATCH_JEV ask | complete)
      if $run.exit_code == 0 { ($run.stdout | from json).answers.bears_on_workaround.noul } else { null }
    }
    $pr | insert related $related
  }
}

# A related pull request seen for the first time, or reaching unstable.
export def related-events [entry: record, related: list<record>, seen: list<record>]: nothing -> list<record> {
  $related | each {|pr|
    let before = ($seen | where key == $"($entry.package)#($pr.number)" | get --optional 0)
    if $before == null {
      { package: $entry.package, kind: related, text: $"#($pr.number) may bear on the workaround \(($pr.status)\): ($pr.title)" }
    } else if $pr.landed and not $before.landed {
      { package: $entry.package, kind: landed, text: $"#($pr.number) reached ($pr.reached | where {|b| $b in $channels } | str join ', '): ($pr.title). Check whether it ends the workaround: ($entry.reason)" }
    }
  } | compact
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
export def remember [entry: record, prs: list<record>, judged: list<record> = []]: nothing -> list<record> {
  $prs
  | each {|pr| { key: $"($entry.package)#($pr.number)", status: $pr.status, landed: $pr.landed } }
  | append ($judged | where related != null | each {|pr| { key: $"($entry.package)#($pr.number)", status: $pr.status, landed: $pr.landed, related: $pr.related } })
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
          related: (do $prs ($entry.related? | default []))
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
  let use_jev = ($env.NIXPKGS_WATCH_JEV? | is-not-empty) and ($env.NIXPKGS_WATCH_QUESTIONS? | is-not-empty)
  let min_related = if $use_jev { (open $env.NIXPKGS_WATCH_QUESTIONS).nixpkgs_watch.min_related } else { 1.0 }

  let results = (
    open $env.NIXPKGS_WATCH_STATUS
    | transpose name entry
    | each {|item|
        let entry = $item.entry
        let run = (^$env.NIXPKGS_WATCH_NPR --days $days $entry.package | complete)
        let found = if $run.exit_code == 0 { $run.stdout | parse-npr } else { [] }
        let prs = ($found | own-prs $entry.package)
        let judged = if $use_jev { judge-related $entry ($found | other-prs $entry.package) $seen } else { [] }
        let related = ($judged | where related != null | where related >= $min_related)
        {
          entry: $entry
          prs: $prs
          judged: $judged
          related: $related
          error: (if $run.exit_code != 0 { $run.stderr | str trim | lines | last })
          events: (if $run.exit_code == 0 { events $entry $prs $seen | append (related-events $entry $related $seen) } else { [] })
        }
      }
  )

  # A failed search keeps what was seen, so its changes still show next time.
  let failed = ($results | where error != null | get entry.package)
  let kept = ($seen | where {|row| ($row.key | split row --regex '[#@]' | first) in $failed })
  $results | where error == null | each {|r| remember $r.entry $r.prs $r.judged } | flatten | append $kept | save --force $seen_file

  let events = ($results | get events | flatten)
  let report = {
    checked: (date now | format date "%+")
    days: $days
    entries: ($results | each {|r|
      $r.entry | select package version nixpkgs ready reason | merge {
        open: ($r.prs | where status == open | get number)
        landed: ($r.prs | where landed | get number)
        related: ($r.related | get number)
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
