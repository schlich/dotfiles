# Keep the ci flake input on ci's latest release. When a release tag on the
# mirror is ahead of what `main` pins, open a topic that runs
# `nix flake update ci`, declare it `behavior`, dispatch it, and say so with a
# desktop notification. Landing stays a deliberate step: `ci land` and
# `ci park` from that workspace.
#
#   ci-input-watch          what main pins, the latest release, any open bump
#   ci-input-watch check    open and dispatch a bump when one is due
#   ci-input-watch on-log   check when the ci log gained a release (the path unit)
#
# `ci land` tags releases on this machine and records each in the ci log as
# a `ci.release` record, so a path unit on the log wakes `on-log`, which reads
# only what was appended since its last run and surveys the mirror only when
# that holds a release. A release of any repository counts: it may be ci's,
# or a landed bump that frees the way for a release that waited behind it.
#
# The wrapper sets CI_INPUT_WATCH_REPO (the dotfiles checkout) and
# CI_INPUT_WATCH_NOTIFY (notify-send); ci, jj, nix, git, gh and tail come from
# PATH. CI_LOG moves the ci log, as it does for ci.

const upstream = "schlich/ci"
const workspace = "ci-input-update"

# The release versions in a stretch of the ci log, one OTLP/JSON request per
# line. Only lines that name the event are decoded; a torn line is skipped.
export def releases-in []: string -> list<string> {
  lines
  | where {|line| $line =~ '"eventName":"ci\.release"' }
  | each {|line|
    try {
      $line | from json | get resourceLogs | get scopeLogs | flatten | get logRecords | flatten
      | where eventName == "ci.release"
      | each {|record| $record.attributes | where key == "ci.release.version" | get value.stringValue }
      | flatten
    } catch { [] }
  }
  | flatten
}

# Where the next unread record starts: past the last complete line of
# `chunk`, read from `offset`. A line still being appended waits for the next
# run.
export def next-offset [offset: int]: string -> int {
  let end = ($in | encode utf8 | bytes index-of --end 0x[0a])
  if $end < 0 { $offset } else { $offset + $end + 1 }
}

# Release tags are YYYY.MM.DD.N, so the latest is the largest by number, not
# by name: 2026.10.19.10 follows 2026.10.19.9.
export def latest-release []: list<record> -> any {
  let releases = (
    $in
    | where {|t| $t.tag =~ '^\d{4}\.\d{2}\.\d{2}\.\d+$' }
    | insert key {|t| $t.tag | split row . | into int | reduce --fold 0 {|part, acc| $acc * 10000 + $part } }
    | sort-by key
  )
  if ($releases | is-empty) { null } else { $releases | last | reject key }
}

# `git ls-remote --tags` lists each tag's object, and an annotated tag again
# as `TAG^{}` with the commit it points at, which is the one to compare.
export def parse-tags []: string -> list<record> {
  lines
  | parse "{commit}\trefs/tags/{tag}"
  | update tag { str replace --regex '\^\{\}$' '' }
  | reverse
  | uniq-by tag
  | reverse
}

# GitHub's compare status for base...head: the release is news when it holds
# commits the pinned revision lacks.
export def bump-due [status: string]: nothing -> bool {
  $status in [ahead diverged]
}

def repo [] {
  $env.CI_INPUT_WATCH_REPO? | default ($env.HOME | path join dotfiles)
}

def state-dir [] {
  $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state)
}

def ci-log [] {
  if ($env.CI_LOG? | is-not-empty) { $env.CI_LOG } else { state-dir | path join ci log.otlp.jsonl }
}

# How far into the ci log `on-log` has read, in bytes.
def offset-file [] {
  state-dir | path join ci-input-watch log-offset
}

def notify [summary: string, body: string] {
  try { ^$env.CI_INPUT_WATCH_NOTIFY --app-name ci-input-watch $summary $body } catch { }
}

# Run an external step in a directory, failing with its label and last line.
def step [label: string, dir: path, run: closure] {
  let result = (do { cd $dir; do $run } | complete)
  if $result.exit_code != 0 {
    let detail = ([$result.stderr $result.stdout] | str join "\n" | str trim | lines | last | default "")
    error make --unspanned { msg: $"($label) failed: ($detail)" }
  }
  $result.stdout
}

def pinned [repo: path] {
  let lock = (step "reading main's flake.lock" $repo { ^jj file show -r "trunk()" flake.lock } | from json)
  let node = ($lock.nodes | get $lock.root | get inputs.ci)
  $lock.nodes | get $node | get locked.rev
}

def survey [] {
  let repo = (repo)
  # GitHub hosts main; Tangled only mirrors it.
  step "fetching trunk" $repo { ^jj git fetch --remote origin } | ignore
  let rev = (pinned $repo)
  let release = (
    step "listing ci releases" $repo { ^git ls-remote --tags $"https://github.com/($upstream)" }
    | parse-tags
    | latest-release
  )
  if $release == null { error make --unspanned { msg: $"($upstream) has no release tags." } }
  let status = if $release.commit == $rev { "identical" } else {
    step "comparing the release with main's pin" $repo {
      ^gh api $"repos/($upstream)/compare/($rev)...($release.commit)" --jq .status
    } | str trim
  }
  {
    repo: $repo
    pinned: $rev
    release: $release
    status: $status
    due: (bump-due $status)
    open: ($repo | path join .jj-workspaces $workspace)
  }
}

def main [] {
  let s = (survey)
  print $"main pins ci ($s.pinned | str substring 0..11); latest release ($s.release.tag) is ($s.status)."
  if ($s.open | path exists) {
    print $"A bump is open in ($s.open); land it there with `ci land`, then `ci park`."
  } else if $s.due {
    print "A bump is due; `ci-input-watch check` opens it."
  }
}

def "main check" [] {
  let s = (survey)
  if not $s.due {
    print $"main already has ci ($s.release.tag)."
    return
  }
  if ($s.open | path exists) {
    print $"A bump is already open in ($s.open); ($s.release.tag) waits until it lands."
    return
  }
  let tag = $s.release.tag
  let outcome = try {
    step "starting the topic" $s.repo { ^ci start $workspace } | ignore
    step "naming the topic" $s.open { ^ci new -m $"Update the ci input to ($tag)" } | ignore
    step "updating the ci input" $s.open { ^nix flake update ci --flake path:. } | ignore
    if (step "reading the change" $s.open { ^jj diff --name-only } | str trim | is-empty) {
      step "dropping the empty topic" $s.open { ^ci cancel } | ignore
      "unchanged"
    } else {
      step "declaring the impact" $s.open { ^ci impact set behavior } | ignore
      step "dispatching" $s.open { ^ci dispatch } | ignore
      "dispatched"
    }
  } catch {|e|
    notify $"ci-input-watch: bump to ($tag) failed" $"($e.msg) Inspect ($s.open)."
    error make --unspanned { msg: $e.msg }
  }
  if $outcome == "unchanged" {
    print $"The ci input already follows ($tag) on main; nothing to dispatch."
    return
  }
  print $"Dispatched the ci input update to ($tag) from ($s.open)."
  notify $"ci ($tag) is ready to land" $"Dispatched in ($s.open). Run `ci land` there, then `ci park`."
}

# The offset is saved before checking, so a failed check notifies once
# rather than on every later write to the log; `ci-input-watch check` retries
# it. Without a saved offset, or once the log was replaced by a shorter one,
# there is no telling what was missed, so it checks once.
def "main on-log" [] {
  let log = (ci-log)
  if not ($log | path exists) { return }
  let mark = (offset-file)
  let size = (ls $log | get 0.size | into int)
  let seen = (try { open --raw $mark | str trim | into int } catch { null })
  mkdir ($mark | path dirname)
  if $seen == null or $seen > $size {
    $size | into string | save --force $mark
    print "No record of what the ci log held before; checking once."
    main check
    return
  }
  if $seen == $size { return }
  # Through `complete`, which keeps the final newline a plain capture drops.
  let chunk = (^tail --bytes $"+($seen + 1)" $log | complete | get stdout)
  $chunk | next-offset $seen | into string | save --force $mark
  let releases = ($chunk | releases-in)
  if ($releases | is-empty) { return }
  print $"The ci log recorded ($releases | str join ', '); checking for a ci release."
  main check
}
