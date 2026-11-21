# Deliver luvus's integration branch to main. First it works out how risky
# the delivery is from which hosts each changed file reaches and which paths
# it changes. A high-risk delivery stops before anything is pushed until the
# owner approves that exact commit (`--approve REV`). Then
# it pushes the branch to GitHub, waits for nixbot's checks on that commit,
# and moves main to it. The main-checks ruleset admits only a commit whose
# nixbot checks passed, and GitHub refuses a push that is not a
# fast-forward, so this never rewrites main. It waits for homelab to build,
# so agents run it as a `job-log` job.

# vcs.nix replaces this with a store path. Tests replace it with
# LUVUS_DELIVER_DEN, a JSON file of what den-reach.nix returns.
const default_reach = "@reach@"

# Changed paths that always need the owner's approval: secrets, the
# host-local hardware, storage, and key files, and what gates main, the
# ruleset and this classifier with the Den reach it reads.
const approval_paths = ['^secrets/' '^hosts/' '^\.github/rulesets/' '^tools/luvus-deliver\.nu$' '^tools/den-reach\.nix$']

# The files a delivery changes, with their line counts; a binary file has
# none.
def changed-files [root: string, base: string, head: string] {
  let counts = (^git -C $root diff --numstat --no-renames $base $head | lines | parse "{added}\t{removed}\t{path}")
  let count = {|value| if $value == null or $value == "-" { null } else { $value | into int } }
  ^git -C $root diff --name-status --no-renames $base $head | lines | parse "{status}\t{path}" | each {|row|
    let counted = ($counts | where path == $row.path | get -o 0)
    {
      path: $row.path
      status: (match $row.status { "A" => "added", "D" => "deleted", "M" => "modified", _ => "changed" })
      added: (do $count $counted.added?)
      removed: (do $count $counted.removed?)
    }
  }
}

# A path that a Nix file names relative to itself, from the repository's
# root: "" for the root itself, null outside the repository.
def resolve [file: string, ref: string] {
  let joined = ("/r" | path join ($file | path dirname) $ref | path expand --no-symlink)
  if $joined == "/r" { "" } else if ($joined | str starts-with "/r/") { $joined | str substring 3.. } else { null }
}

# Every repository path a Nix file names at `rev`: the modules each aspect
# and module imports, and the files they read. A reference to the root
# itself, as checks and secret paths make, reads nothing in particular.
def references [root: string, rev: string] {
  ^git -C $root grep -n -I -o -E '\.{1,2}/[A-Za-z0-9_./-]*' $rev -- '*.nix'
  | lines
  | parse --regex '^[^:]+:(?<file>[^:]+):(?<line>\d+):(?<ref>.*)$'
  | each {|row| { file: $row.file, line: ($row.line | into int), target: (resolve $row.file $row.ref) } }
  | where {|row| $row.target != null and $row.target != "" }
}

# Where each Den aspect is defined at `rev`: the lines that assign
# `den.aspects.NAME`, not those that only include it.
def aspect-definitions [root: string, rev: string] {
  ^git -C $root grep -n -E '^\s*den\.aspects\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_.-]+)?\s*=' $rev -- 'den/aspects'
  | lines
  | parse --regex '^[^:]+:(?<file>[^:]+):(?<line>\d+):\s*den\.aspects\.(?<name>[A-Za-z0-9_-]+)'
  | update line { into int }
}

# The aspects a line of an aspect file belongs to: the definition above it,
# or every aspect the file defines when none is.
def aspects-at [file: string, line: int, definitions: list] {
  let own = ($definitions | where {|row| $row.file == $file })
  let above = ($own | where {|row| $row.line <= $line })
  if ($above | is-empty) { $own | get name } else { [($above | sort-by line | last | get name)] }
}

# What reads `path`, directly or through the files that import it: the Den
# aspects, whether Den's host composition does, and whether only the
# flake's own outputs, such as its checks, do.
def reach [path: string, refs: list, definitions: list] {
  if ($path | str starts-with "den/aspects/") {
    return { aspects: ($definitions | where {|row| $row.file == $path } | get name | uniq), composition: false, flake: false }
  }
  if ($path | str starts-with "den/") {
    return { aspects: [], composition: true, flake: false }
  }
  mut frontier = [$path]
  mut seen = [$path]
  mut aspects = []
  mut composition = false
  mut flake = ($path == "flake.nix")
  while ($frontier | is-not-empty) {
    let current = ($frontier | first)
    $frontier = ($frontier | skip 1)
    let readers = ($refs | where {|ref|
      $ref.file != $current and ($ref.target == $current or ($current | str starts-with $"($ref.target)/"))
    })
    for ref in $readers {
      if ($ref.file | str starts-with "den/aspects/") {
        $aspects = ($aspects | append (aspects-at $ref.file $ref.line $definitions))
      } else if ($ref.file | str starts-with "den/") {
        $composition = true
      } else if $ref.file == "flake.nix" {
        $flake = true
      } else if $ref.file not-in $seen {
        $seen = ($seen | append $ref.file)
        $frontier = ($frontier | append $ref.file)
      }
    }
  }
  { aspects: ($aspects | uniq | sort), composition: $composition, flake: $flake }
}

# Whether a Nix file changed only in its comments and layout: both versions
# parse to the same expression. One that cannot be parsed counts as changed.
def layout-only [root: string, base: string, head: string, path: string] {
  if not ($path | str ends-with ".nix") { return false }
  let parse = {|rev|
    let source = (^git -C $root show $"($rev):($path)" | complete)
    let parsed = if $source.exit_code == 0 {
      ^nix-instantiate --parse --store dummy:// -E $source.stdout | complete
    } else { { exit_code: 1 } }
    if $parsed.exit_code == 0 { $parsed.stdout } else { null }
  }
  let before = (do $parse $base)
  $before != null and $before == (do $parse $head)
}

def lock-at [root: string, rev: string] {
  let shown = (^git -C $root show $"($rev):flake.lock" | complete)
  if $shown.exit_code == 0 { $shown.stdout | from json } else { { nodes: {} } }
}

# What a lock's node `node` pins: its own locked source and those of
# everything it depends on, by content, so that a lock whose nodes were only
# renumbered pins the same.
def pinned [nodes: record, node: string] {
  mut pending = [$node]
  mut seen = []
  while ($pending | is-not-empty) {
    let next = ($pending | first)
    $pending = ($pending | skip 1)
    if $next not-in $seen {
      $seen = ($seen | append $next)
      # A list is a `follows` path, which names an input another node owns.
      $pending = ($pending | append ($nodes | get -o $next | get -o inputs | default {} | values | where {|v| ($v | describe) == "string" }))
    }
  }
  $seen | each {|name| $nodes | get -o $name | get -o locked | to json --raw } | uniq | sort
}

# A lock's inputs by the names modules use: the root's own, and those of the
# group flakes under lib/inputs, which are relative path inputs. A value that
# is not a string is a `follows` path.
def leaf-inputs [nodes: record, node: string = "root"] {
  $nodes | get -o $node | get -o inputs | default {} | transpose name node | reduce --fold {} {|row, all|
    let target = if ($row.node | describe) == "string" { $nodes | get -o $row.node } else { null }
    if $target != null and ($target | get -o locked.type) == "path" and ($target | get -o parent) != null {
      $all | merge (leaf-inputs $nodes $row.node)
    } else {
      $all | insert $row.name $row.node
    }
  }
}

# The flake inputs a delivery updates, by the names modules use: those it
# adds, and those whose locked source, or that of anything they depend on,
# changed.
def updated-inputs [root: string, base: string, head: string] {
  let before = (lock-at $root $base).nodes
  let after = (lock-at $root $head).nodes
  let old_roots = (leaf-inputs $before)
  leaf-inputs $after | transpose name node | where {|row|
    let old = ($old_roots | get -o $row.name)
    ($row.node | describe) == "string" and (
      ($old | describe) != "string" or (pinned $after $row.node) != (pinned $before $old)
    )
  } | get name
}

# The files at `rev` that use flake input `name`.
def input-readers [root: string, rev: string, name: string] {
  let found = (^git -C $root grep -l -E $"inputs\\.\"?($name)\"?\([^A-Za-z0-9_-]|$\)" $rev -- '*.nix' | complete)
  $found.stdout | lines | each { str replace --regex '^[^:]+:' '' }
}

# What reads the inputs a flake.lock change updates, from the files that
# use them.
def lock-reach [readers: list, refs: list, definitions: list] {
  let found = ($readers | each {|file| reach $file $refs $definitions })
  {
    aspects: ($found | get aspects | flatten | uniq | sort)
    composition: ($found | any {|f| $f.composition })
    flake: ($found | any {|f| $f.flake })
  }
}

# Which Den aspects each host's system and each home includes, from
# den-reach.nix evaluated at `rev`.
def den-reach [root: string, rev: string] {
  if ($env.LUVUS_DELIVER_DEN? | is-not-empty) {
    return (open $env.LUVUS_DELIVER_DEN)
  }
  let reach_file = ($env.LUVUS_DELIVER_REACH? | default $default_reach)
  let result = (^nix eval --json $"git+file://($root)?rev=($rev)#den" --apply (open --raw $reach_file) | complete)
  if $result.exit_code != 0 {
    let detail = ($result.stderr | lines | where {|line| $line =~ 'error' } | get -o 0 | default ($result.stderr | str trim))
    error make { msg: $"evaluating Den at ($rev | str substring 0..11) failed: ($detail)" }
  }
  $result.stdout | from json
}

# The hosts whose system, and the homes, that include any aspect `found`
# names; Den's host composition reaches all of them.
def hosts-of [found: record, den: record] {
  let including = {|table| $table | transpose name aspects | where {|row|
    $found.composition or ($row.aspects | any {|aspect| $aspect in $found.aspects })
  } | get name }
  { systems: (do $including $den.systems), homes: (do $including $den.homes) }
}

const risk_levels = [low medium high critical]

# The highest risk den/model/policy.nix assigns an aspect a file reaches, or null;
# Den's host composition reaches every aspect.
def policy-risk [found: record, risks: record] {
  let named = if $found.composition { $risks | values } else { $found.aspects | each {|aspect| $risks | get -o $aspect } }
  let ranks = ($named | where {|risk| $risk in $risk_levels } | each {|risk| $risk_levels | enumerate | where item == $risk | get 0.index })
  if ($ranks | is-empty) { null } else { $risk_levels | get ($ranks | math max) }
}

# How risky delivering `head` onto `base` is, and why. A delivery is high
# risk, and needs the owner's approval, when it changes a path that always
# needs approval, when it reaches several deployed hosts through
# configuration den/model/policy.nix rates high or critical, and when which
# hosts it reaches cannot be worked out. It is low when no host runs
# anything it changes, and medium otherwise.
def classify [root: string, base: string, head: string] {
  let files = (changed-files $root $base $head)
  let refs = (references $root $head)
  let definitions = (aspect-definitions $root $head)
  let inputs = if ($files | any {|file| $file.path == "flake.lock" }) { updated-inputs $root $base $head } else { [] }
  let den = (try { { reach: (den-reach $root $head) } } catch {|err| { error: $err.msg } })
  let files = ($files | each {|file|
    let layout_only = ($file.status == "modified" and (layout-only $root $base $head $file.path))
    let found = if $file.status == "deleted" or $layout_only {
      # A deleted file's importers changed as well and reach the same hosts;
      # a comment or layout edit changes what no host runs.
      { aspects: [], composition: false, flake: false }
    } else if $file.path == "flake.lock" {
      let readers = ($inputs | each {|name| input-readers $root $head $name } | flatten | uniq)
      lock-reach $readers $refs $definitions
    } else {
      reach $file.path $refs $definitions
    }
    let hosts = if $den.reach? != null { hosts-of $found $den.reach } else { { systems: [], homes: [] } }
    let policy = if $den.reach? != null { policy-risk $found ($den.reach.risks? | default {}) } else { null }
    $file | merge { layout_only: $layout_only, aspects: $found.aspects, policy_risk: $policy } | merge $hosts
  })
  let deployed = ($den.reach?.deployed? | default [])
  let hosts = ($files | each {|file| $file.systems ++ ($file.homes | each { split row "@" | last }) } | flatten | uniq | where {|host| $host in $deployed } | sort)

  let reasons = (
    []
    | append (if $den.error? != null { [$"which hosts it reaches is unknown: ($den.error)"] } else { [] })
    # Several hosts count through configuration den/model/policy.nix rates
    # high or critical, such as deployment or servers.
    | append ($files | where {|file|
      $file.policy_risk in [high critical] and (($file.systems ++ ($file.homes | each { split row "@" | last })) | uniq | where {|host| $host in $deployed } | length) >= 2
    } | each {|file| $"($file.path) reaches several hosts through ($file.policy_risk)-risk configuration" })
    | append ($files | where {|file| $approval_paths | any {|pattern| $file.path =~ $pattern } } | each {|file| $"($file.path) always needs approval" })
  )
  let reaches_hosts = ($files | any {|file| ($file.systems | is-not-empty) or ($file.homes | is-not-empty) })
  {
    base: $base
    head: $head
    risk: (if ($reasons | is-not-empty) { "high" } else if not $reaches_hosts { "low" } else { "medium" })
    reasons: $reasons
    hosts: $hosts
    inputs: $inputs
    files: ($files | select path status layout_only systems homes aspects policy_risk)
  }
}

def summary [verdict: record] {
  let short = ($verdict.head | str substring 0..11)
  let reach = if ($verdict.hosts | is-empty) { "no deployed host" } else { $verdict.hosts | str join ", " }
  let why = ($verdict.reasons | each {|reason| $"\n  - ($reason)" } | str join "")
  $"Risk of delivering ($short): ($verdict.risk); it reaches ($reach).($why)"
}

def ledger [] {
  let state = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
  $env.LUVUS_DELIVER_LEDGER? | default ($state | path join "luvus-deliver" "risk.jsonl")
}

# Keep each delivery's verdict, for review after landing. A ledger that cannot be written never stops a delivery.
def record-verdict [verdict: record, approved: bool] {
  try {
    let path = (ledger)
    mkdir ($path | path dirname)
    let entry = {
      at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
      base: $verdict.base
      head: $verdict.head
      risk: $verdict.risk
      hosts: $verdict.hosts
      reasons: $verdict.reasons
      approved: $approved
    }
    $"($entry | to json --raw)\n" | save --append $path
  }
}

# luvus starts a board task's worktree from the local main branch, which
# nothing else moves, so tasks began on a main weeks old. Move it to what was
# delivered, as a fast-forward, unless a checkout has it.
def advance-local-main [root: string, sha: string] {
  let checked_out = (^git -C $root worktree list --porcelain | lines | any {|line| $line == "branch refs/heads/main" })
  let local = (^git -C $root rev-parse --verify --quiet refs/heads/main | complete)
  if $checked_out {
    print "Left local main alone: a worktree has it checked out."
  } else if $local.exit_code != 0 {
    ^git -C $root update-ref refs/heads/main $sha
  } else if (^git -C $root merge-base --is-ancestor ($local.stdout | str trim) $sha | complete).exit_code == 0 {
    ^git -C $root update-ref refs/heads/main $sha ($local.stdout | str trim)
  } else {
    print "Left local main alone: it has commits this delivery lacks."
  }
}

# The integration branch's head and main's, with main fetched first.
def endpoints [repo: path, branch: string] {
  let root = (^git -C $repo rev-parse --show-toplevel | str trim)
  let sha = (^git -C $root rev-parse --verify $"($branch)^{commit}" | str trim)
  ^git -C $root fetch --quiet origin main
  { root: $root, sha: $sha, main: (^git -C $root rev-parse origin/main | str trim) }
}

# Judge how risky delivering the branch would be, without delivering it.
def "main risk" [
  --repo: path = "."                     # Any checkout of the repository
  --branch: string = "luvus/integration" # The branch luvus merges finished tasks into
  --json                                 # Print the verdict as JSON
] {
  let at = (endpoints $repo $branch)
  if $at.main == $at.sha {
    print "main is already there; nothing to deliver."
    return
  }
  let verdict = (classify $at.root $at.main $at.sha)
  if $json { $verdict | to json } else { summary $verdict }
}

def main [
  --repo: path = "."                     # Any checkout of the repository
  --branch: string = "luvus/integration" # The branch luvus merges finished tasks into
  --check: list<string> = [nixbot/nix-eval nixbot/nix-build] # The required check runs on GitHub
  --approve: string                      # The commit the owner approved, for a high-risk delivery
  --timeout: duration = 2hr
  --poll: duration = 30sec
] {
  let at = (endpoints $repo $branch)
  let root = $at.root
  let sha = $at.sha
  let main = $at.main
  let short = ($sha | str substring 0..11)
  if $main == $sha {
    print $"main is already at ($short)."
    return
  }
  if (^git -C $root merge-base --is-ancestor $main $sha | complete).exit_code != 0 {
    error make { msg: $"($branch) does not contain origin/main; merge main into it before delivering." }
  }
  # An approval names the commit the owner saw, never a branch, so it cannot
  # carry over to commits merged after it.
  let approved = if $approve == null { false } else {
    let named = (^git -C $root rev-parse --verify --quiet $"($approve)^{commit}" | complete)
    if $approve !~ '^[0-9a-f]{7,40}$' or $named.exit_code != 0 or ($named.stdout | str trim) != $sha {
      error make { msg: $"--approve names ($approve), but this delivery is ($short); approval covers one exact commit." }
    }
    true
  }
  let verdict = (classify $root $main $sha)
  print (summary $verdict)
  record-verdict $verdict $approved
  if $verdict.risk == "high" and not $approved {
    error make { msg: $"Delivering ($short) needs the owner's approval first. Show them the reasons above, and once they approve this commit, run `luvus-deliver --approve ($short)`." }
  }
  print $"Pushing ($branch) at ($short)."
  ^git -C $root push --quiet origin $"($sha):refs/heads/($branch)"
  let slug = (do { cd $root; ^gh repo view --json nameWithOwner --jq .nameWithOwner } | str trim)
  let deadline = ((date now) + $timeout)
  # GitHub counts these conclusions as passing a required check.
  let passing = [success neutral skipped]
  loop {
    let latest = $check | each {|name|
      ^gh api --method GET $"repos/($slug)/commits/($sha)/check-runs" -f $"check_name=($name)"
      | from json
      | get check_runs
      | where status == completed
      | sort-by completed_at
      | last
      | default { name: $name, conclusion: null }
    }
    # A failed eval means nix-build may never report, so stop at the first failure.
    let failed = $latest | where conclusion != null and conclusion not-in $passing
    if ($failed | is-not-empty) {
      let first = $failed | first
      error make { msg: $"`($first.name)` concluded ($first.conclusion) on ($short): ($first.html_url? | default '')" }
    }
    let pending = $latest | where conclusion == null | get name
    if ($pending | is-empty) { break }
    if (date now) > $deadline {
      error make { msg: $"Timed out after ($timeout) waiting for ($pending | str join ', ') on ($short)." }
    }
    print $"Waiting for ($pending | str join ', ') on ($short)."
    sleep $poll
  }
  ^git -C $root push --quiet origin $"($sha):refs/heads/main"
  advance-local-main $root $sha
  print $"Delivered: main is now ($short)."
}
