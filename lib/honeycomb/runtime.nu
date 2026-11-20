# honeycomb: the rule of six for what a repository accumulates while work is
# under way (lib/honeycomb/README.md). `honeycomb census` counts the open
# topics, worktrees and tasks of the repository it runs in and says which
# pass six; `honeycomb prune` removes what trunk already holds.

const limit = 6
# Branches that are part of the workflow itself, never a topic.
const fixed = [main master luvus/integration]

def --wrapped git-lines [...args: string] {
  let result = (^git ...$args | complete)
  if $result.exit_code == 0 { $result.stdout | lines | where $it != "" } else { [] }
}

def trunk [] {
  let found = ([origin/main origin/master main master] | where {|ref| (^git rev-parse --verify --quiet $ref | complete).exit_code == 0 })
  if ($found | is-empty) { error make --unspanned { msg: "no main or master branch here" } }
  $found | first
}

# Local branches with whether trunk already holds their commits.
def branches [] {
  let trunk = (trunk)
  let merged = (git-lines branch --merged $trunk --format "%(refname:short)")
  git-lines branch --format "%(refname:short)" | where {|name| $name not-in $fixed and not ($name | str starts-with "(") } | each {|name|
    { name: $name, delivered: ($name in $merged) }
  }
}

# Worktrees other than the first, which is the shared checkout, and the one
# luvus integrates in.
def worktrees [] {
  ^git worktree list --porcelain | split row "\n\n" | where $it != "" | skip 1 | each {|block|
    let fields = ($block | lines | parse --regex '^(?<key>\S+) ?(?<value>.*)$')
    let path = ($fields | where key == worktree | get 0.value)
    { path: $path, branch: ($fields | where key == branch | get 0?.value | default "" | str replace "refs/heads/" "") }
  } | where {|tree| ($tree.path | path basename) != "__integration" }
}

# Open luvus tasks for this repository, when luvus runs here.
def open-tasks [] {
  if (which luvus | is-empty) { return [] }
  let listed = (^luvus task list | complete)
  if $listed.exit_code != 0 { return [] }
  let root = (^git rev-parse --path-format=absolute --git-common-dir | str trim)
  try {
    $listed.stdout | from json | get result.tasks | where {|task| ($task.project?.root? | default $root) == $root and $task.status in [queued running review blocked] }
  } catch { [] }
}

# Count this repository's open topics, worktrees and tasks against six.
def "main census" [
  --json # Print the counts as JSON.
] {
  let branches = (branches)
  let trees = (worktrees)
  let open = ($branches | where not delivered | get name)
  let rows = [
    { collection: "open topics", count: ($open | length), members: $open }
    { collection: "worktrees", count: ($trees | length), members: ($trees | get path | path basename) }
    { collection: "open tasks", count: (open-tasks | length), members: (open-tasks | each {|task| $"($task.id) ($task.status)" }) }
  ] | insert over {|row| $row.count > $limit }
  let delivered = ($branches | where delivered | get name)
  let result = { limit: $limit, collections: $rows, delivered: $delivered }
  if $json { return ($result | to json) }
  print ($rows | each {|row| $"($row.collection): ($row.count) of ($limit)(if $row.over { '  over: finish or park one before starting another' } else { '' })" } | str join "\n")
  if ($delivered | is-not-empty) {
    print $"($delivered | length) branches are already on (trunk); `honeycomb prune` lists them."
  }
}

# Remove the branches trunk already holds, with their worktrees. Lists them
# unless --yes is given. A worktree with uncommitted work, or one luvus says
# is in use, is left alone, and so is its branch.
def "main prune" [
  --yes # Remove them instead of listing them.
] {
  let trunk = (trunk)
  let current = (^git branch --show-current | str trim)
  let trees = (worktrees)
  let delivered = (branches | where delivered and name != $current | get name)
  if ($delivered | is-empty) { print $"Nothing to prune: no branch is already on ($trunk)."; return }
  let plan = ($delivered | each {|name| { branch: $name, worktree: ($trees | where branch == $name | get 0?.path) } })
  if not $yes {
    print ($plan | each {|row| $"($row.branch)(if $row.worktree != null { $'  with ($row.worktree)' } else { '' })" } | str join "\n")
    print $"\n($plan | length) branches are already on ($trunk). `honeycomb prune --yes` removes them."
    return
  }
  let done = ($plan | each {|row|
    let tree = if $row.worktree == null {
      { ok: true, note: "" }
    } else if ((git-lines -C $row.worktree status --porcelain) | is-not-empty) {
      { ok: false, note: "uncommitted work" }
    } else {
      let managed = ($row.worktree | str contains "/.luvus/worktrees/") and (which luvus | is-not-empty)
      let removed = if $managed { ^luvus worktree remove $row.worktree | complete } else { ^git worktree remove $row.worktree | complete }
      { ok: ($removed.exit_code == 0), note: (if $removed.exit_code == 0 { "" } else { $removed.stdout + $removed.stderr | str trim | lines | last | default "in use" }) }
    }
    # -D is safe here: trunk holds every commit of a delivered branch.
    let branch = if $tree.ok { (^git branch -D $row.branch | complete).exit_code == 0 } else { false }
    { branch: $row.branch, removed: $branch, kept_because: $tree.note }
  })
  print $"Removed ($done | where removed | length) of ($done | length) branches."
  let kept = ($done | where not removed)
  if ($kept | is-not-empty) { print ($kept | each {|row| $"kept ($row.branch): ($row.kept_because)" } | str join "\n") }
}

def main [] {
  print "Usage: honeycomb (census [--json] | prune [--yes])"
}
