# Keep the ci flake input on ci's latest release. When a release tag on the
# mirror is ahead of what `main` pins, open a topic that runs
# `nix flake update ci`, declare it `behavior`, dispatch it, and say so with a
# desktop notification. Landing stays a deliberate step: `ci land` and
# `ci park` from that workspace.
#
#   ci-input-watch          what main pins, the latest release, any open bump
#   ci-input-watch check    open and dispatch a bump when one is due (the timer)
#
# The wrapper sets CI_INPUT_WATCH_REPO (the dotfiles checkout) and
# CI_INPUT_WATCH_NOTIFY (notify-send); ci, jj, nix, git and gh come from PATH.

const upstream = "schlich/ci"
const workspace = "ci-input-update"

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
  step "fetching trunk" $repo { ^jj git fetch --remote tangled } | ignore
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
