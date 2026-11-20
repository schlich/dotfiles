# honeycomb: the rule of six for what accumulates while work is under way
# (lib/honeycomb/README.md).
#
#   census    this repository's open topics, worktrees and tasks, luvus's
#             workspaces, and Claude's sessions per area, against six
#   prune     remove the branches trunk already holds, with their worktrees
#             and the luvus workspaces open on them
#   sidebar   file Claude's sessions under the seven areas: its sidebar
#             becomes Home, the six areas around it, and the unfiled list
#   sessions  each area's live Claude sessions, and the ones to archive so
#             that none holds more than six
#   flower    what each area holds now, as the phone shows it
#   hub sync  send that to the hub on homelab and apply the actions queued
#             on the phone (lib/honeycomb/runtime/hub)
#
# The areas are lib/honeycomb/default.nix's, in the JSON file that
# $env.HONEYCOMB_AREAS names (the installed command sets it).

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

# luvus's open workspaces, when luvus runs here.
def luvus-workspaces [] {
  if (which luvus | is-empty) { return [] }
  let listed = (^luvus workspace list | complete)
  if $listed.exit_code != 0 { return [] }
  try { $listed.stdout | from json | get result.workspaces } catch { [] }
}

# Close the luvus workspace open on a directory, if one is.
def close-luvus-workspace [directory: string] {
  let found = (luvus-workspaces | where cwd == $directory)
  if ($found | is-not-empty) { ^luvus workspace close ($found | get 0.workspace) | complete | ignore }
}

# The seven areas, centre first and then the six around it.
def areas [file?: path] {
  let file = ($file | default ($env.HONEYCOMB_AREAS? | default ""))
  if $file == "" or not ($file | path exists) {
    error make --unspanned { msg: "no areas file: set HONEYCOMB_AREAS or pass --areas" }
  }
  open $file
}

def claude-root [] { $env.HOME | path join .config Claude }
def claude-config [] { claude-root | path join claude_desktop_config.json }

# Whether the Claude desktop app runs. It keeps its sidebar and sessions in
# memory and writes them back, so they are changed only while it is closed.
def claude-running [] {
  ps --long | where {|process| ($process.command? | default "") =~ 'lib/claude-desktop/' } | is-not-empty
}

# The Claude desktop app's code sessions under a root.
def claude-sessions [root: path] {
  glob ($root | path join claude-code-sessions "*" "*" "local_*.json") | each {|file|
    let session = (open $file)
    {
      key: $"code:($session.sessionId? | default ($file | path parse | get stem))"
      file: $file
      cwd: ($session.cwd? | default "")
      title: ($session.title? | default "")
      archived: ($session.isArchived? | default false)
      active: ($session.lastActivityAt? | default 0)
      # A session under Remote Control opens on claude.ai and in the
      # Claude mobile app.
      link: ($session.bridgeSessionIds? | default [] | last | if $in == null { null } else { $"https://claude.ai/code/($in)" })
    }
  }
}

# The area whose folders hold a directory: one under $HOME, or a luvus
# worktree of a repository there.
def folder-area [areas: list, directory: string] {
  let home = $env.HOME
  if not ($directory | str starts-with $"($home)/") { return null }
  let relative = ($directory | path relative-to $home | str replace --regex '^\.luvus/worktrees/([^/]+)/[^/]+' '$1')
  $areas | where {|area| $area.folders | any {|folder| $relative == $folder or ($relative | str starts-with $"($folder)/") } } | get 0?.name
}

# The project a directory belongs to, relative to $HOME: its first folder, or
# its first two under Projects, seen through luvus's and Claude's worktrees.
# Claude's scratch workspaces belong to none.
def folder-key [directory: string] {
  let home = $env.HOME
  if not ($directory | str starts-with $"($home)/") { return null }
  let relative = ($directory | path relative-to $home
    | str replace --regex '^\.luvus/worktrees/([^/]+)/[^/]+' '$1'
    | str replace --regex '/\.claude/worktrees/.*$' '')
  if ($relative | str starts-with ".config/") { return null }
  let parts = ($relative | split row "/")
  if $parts.0 == "Projects" and ($parts | length) > 1 { $parts | first 2 | str join "/" } else { $parts.0 }
}

# The area a sidebar section belongs to: the one it is named for, or the one
# that absorbs it.
def section-area [areas: list, name: string] {
  $areas | where {|area| $area.title == $name or $name in $area.absorbs } | get 0?.name
}

def to-record [] { reduce --fold {} {|it, acc| $acc | merge $it } }

# One account's sidebar refiled by area. Each area gets one section: the one
# named for it, else the first it absorbs, else a new one. Sessions keep
# their section's area, and unfiled live sessions take their folder's.
# Sections no area absorbs stay as they are.
def plan-scope [areas: list, sections: list, scope: record, sessions: list] {
  let groups = ($scope.groups? | default [])
  let assignments = ($scope.assignments? | default {})
  let orders = ($scope.order? | default {})
  let ids = ($areas | each {|area|
    let own = ($groups | where name == $area.title | get 0?.id)
    let absorbed = ($area.absorbs | each {|name| $groups | where name == $name | get 0?.id } | compact | get 0?)
    { area: $area.name, id: ($own | default $absorbed | default $"cg-(random uuid)") }
  })
  let target = {|area| $ids | where area == $area | get 0.id }
  let moved = ($groups | each {|group|
    let area = (section-area $areas $group.name)
    { id: $group.id, area: $area, into: (if $area == null { $group.id } else { do $target $area }) }
  })
  let kept = ($moved | where area == null | get id)
  let carried = ($assignments | transpose key group | each {|row|
    { key: $row.key, group: ($moved | where id == $row.group | get 0?.into | default $row.group) }
  })
  # Each project's area, by the most of its filed sessions, so a session
  # dragged into a section teaches the next run where its project goes.
  let learned = ($sessions
    | each {|session|
      let group = ($carried | where key == $session.key | get 0?.group)
      { folder: (folder-key $session.cwd), area: (if $group == null { null } else { $ids | where id == $group | get 0?.area }) }
    }
    | where {|row| $row.folder != null and $row.area != null }
    | group-by folder
    | transpose folder rows
    | each {|project| { folder: $project.folder, area: ($project.rows | get area | uniq --count | sort-by count --reverse | get 0.value) } })
  let filed = ($sessions
    | where {|session| not $session.archived and ($assignments | get --optional $session.key) == null }
    | each {|session|
      let by_folder = (folder-area $areas $session.cwd)
      let key = (folder-key $session.cwd)
      { key: $session.key, area: ($by_folder | default ($learned | where folder == $key | get 0?.area)) }
    }
    | where area != null
    | each {|row| { key: $row.key, group: (do $target $row.area) } })
  let assigned = ($carried | append $filed | reduce --fold {} {|row, acc| $acc | upsert $row.key $row.group })
  let members = ($assigned | transpose key group)
  let new_groups = ($ids | each {|row| { id: $row.id, name: ($areas | where name == $row.area | get 0.title), mode: code } }
    | append ($groups | where id in $kept))
  let order = ($new_groups | each {|group|
    let sources = ($moved | where into == $group.id | get id)
    let listed = ($sources | each {|source| $orders | get --optional $source | default [] } | flatten)
    let mine = ($members | where group == $group.id | each {|row| $row.key })
    { $group.id: ($listed | append $mine | uniq | where {|key| $key in $mine }) }
  } | to-record)
  let template = ($sections | where kind == manual | get 0? | default {
    kind: manual, v: 2, sortBy: recency, ascending: false
    show: { metadata: false, emptyGroups: false, sideChats: false, slack: true }
    collapsed: true, shown: true, members: []
  })
  let template = if "groupBy" in ($template | columns) { $template | reject groupBy } else { $template }
  let manual = ($new_groups | each {|group|
    let base = ($sections | where id == $group.id | get 0? | default ($template | upsert collapsed true))
    $base | upsert id $group.id | upsert name $group.name | upsert kind manual | upsert members ($base.members? | default [])
  })
  let ordered = ($sections | where kind == pinned
    | append ($sections | where kind == routines)
    | append $manual
    | append ($sections | where kind not-in [pinned routines manual sessions])
    | append ($sections | where kind == sessions))
  let area_of = {|group| $ids | where id == $group | get 0?.area }
  {
    sections: ($ordered | enumerate | each {|row| $row.item | upsert order $row.index })
    scope: ($scope | upsert groups $new_groups | upsert assignments $assigned | upsert order $order)
    sessions: ($sessions | each {|session|
      let group = ($assigned | get --optional $session.key)
      $session | insert area (if $group == null { null } else { do $area_of $group })
    })
    absorbed: ($moved | where area != null | each {|row| { area: $row.area, name: ($groups | where id == $row.id | get 0.name) } })
    kept: ($groups | where id in $kept | get name)
  }
}

# Every account's sidebar refiled; sessions are matched to an account by
# the directory they are stored under.
def sidebar-plan [prefs: record, sessions: list, areas: list] {
  let section_scopes = ($prefs | get --optional "dframe-code-sections" | default {})
  let group_scopes = ($prefs | get --optional "dframe-group-scopes" | default {})
  let planned = ($section_scopes | columns | each {|key|
    let mine = ($sessions | where {|session| $session.file | str contains $"/($key)/" })
    { key: $key, plan: (plan-scope $areas ($section_scopes | get $key | get sections) ($group_scopes | get --optional $key | default {}) $mine) }
  })
  {
    sections: ($planned | reduce --fold $section_scopes {|row, acc| $acc | upsert $row.key (($acc | get $row.key) | upsert sections $row.plan.sections) })
    scopes: ($planned | reduce --fold $group_scopes {|row, acc| $acc | upsert $row.key $row.plan.scope })
    sessions: ($planned | each {|row| $row.plan.sessions } | flatten)
    absorbed: ($planned | each {|row| $row.plan.absorbed } | flatten | uniq)
    kept: ($planned | each {|row| $row.plan.kept } | flatten | uniq)
  }
}

# Live sessions per area, most recently active first, each marked when its
# directory is gone or when it is past the sixth of its area.
def ranked [sessions: list] {
  $sessions
  | where not archived
  | update area {|session| $session.area | default unfiled }
  | group-by area
  | values
  | each {|rows| $rows | sort-by active --reverse | enumerate | each {|row| $row.item | insert gone (not ($row.item.cwd | path exists)) | insert beyond ($row.index >= $limit) } }
  | flatten
}

def per-area [areas: list, live: list] {
  $areas | each {|area| { area: $area.name, cell: $area.cell, title: $area.title } }
  | append { area: unfiled, cell: out, title: "unfiled" }
  | each {|row| $row | insert live ($live | where area == $row.area | length) }
}

def plan-from [config: path, root: path, areas: list] {
  let config_data = (open $config)
  sidebar-plan ($config_data.preferences?.epitaxyPrefs? | default {}) (claude-sessions $root) $areas
}

# Count this repository's open topics, worktrees and tasks, luvus's
# workspaces, and Claude's live sessions per area against six.
def "main census" [
  --json # Print the counts as JSON.
] {
  let branches = (branches)
  let trees = (worktrees)
  let open = ($branches | where not delivered | get name)
  let tasks = (open-tasks)
  let spaces = (luvus-workspaces)
  let rows = [
    { collection: "open topics", count: ($open | length), members: $open }
    { collection: "worktrees", count: ($trees | length), members: ($trees | get path | path basename) }
    { collection: "open tasks", count: ($tasks | length), members: ($tasks | each {|task| $"($task.id) ($task.status)" }) }
    { collection: "luvus workspaces", count: ($spaces | length), members: ($spaces | get name) }
  ]
  let claude = if (claude-config | path exists) and ($env.HONEYCOMB_AREAS? | default "" | path exists) {
    let plan = (plan-from (claude-config) (claude-root) (areas))
    per-area (areas) (ranked $plan.sessions) | each {|row| { collection: $"Claude sessions in ($row.title)", count: $row.live, members: [] } }
  } else { [] }
  let rows = ($rows | append $claude | insert over {|row| $row.count > $limit })
  let delivered = ($branches | where delivered | get name)
  let result = { limit: $limit, collections: $rows, delivered: $delivered }
  if $json { return ($result | to json) }
  let shown = ($rows | where {|row| not ($row.collection | str starts-with "Claude") or $row.over })
  print ($shown | each {|row| $"($row.collection): ($row.count) of ($limit)(if $row.over { '  over: finish or park one before starting another' } else { '' })" } | str join "\n")
  if ($delivered | is-not-empty) {
    print $"($delivered | length) branches are already on (trunk); `honeycomb prune` lists them."
  }
  if ($claude | where {|row| $row.count > $limit } | is-not-empty) {
    print "`honeycomb sessions` lists the Claude sessions to archive."
  }
}

# Remove the branches trunk already holds, with their worktrees and the luvus
# workspaces open on them. Lists them unless --yes is given. A worktree with
# uncommitted work, or one luvus says is in use, is left alone, and so is its
# branch.
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
      if $removed.exit_code == 0 { close-luvus-workspace $row.worktree }
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

# File Claude's sessions under the seven areas. The sidebar becomes Home and
# the six areas around it, in compass order, between the pinned sessions and
# the unfiled list; the sections each area absorbs merge into it, and an
# unfiled session joins its folder's area, or the area most of its project's
# filed sessions are in. Prints the
# plan unless --apply is given, which writes it (keeping a copy of the old
# file) and needs the Claude desktop app closed.
def "main sidebar" [
  --apply # Write the refiled sidebar.
  --json # Print the planned sidebar as JSON.
  --config: path # The desktop app's config (default: its own).
  --root: path # Where its sessions are kept (default: its own).
  --areas: path # The areas (default: $env.HONEYCOMB_AREAS).
] {
  let config = ($config | default (claude-config))
  let root = ($root | default (claude-root))
  let areas = (areas $areas)
  let plan = (plan-from $config $root $areas)
  if $json { return ({ sections: $plan.sections, scopes: $plan.scopes } | to json) }
  if not $apply {
    let live = (ranked $plan.sessions)
    print "Claude's sidebar, filed by area (live sessions):"
    print (per-area $areas $live | each {|row|
      let from = ($plan.absorbed | where area == $row.area | get name | where {|name| $name != $row.title })
      $"  ($row.cell | fill --width 6) ($row.title | fill --width 12) ($row.live | fill --alignment right --width 3)(if $row.live > $limit { ' over' } else { '     ' })(if ($from | is-not-empty) { $'  absorbs ($from | str join ", ")' } else { '' })"
    } | str join "\n")
    if ($plan.kept | is-not-empty) { print $"Sections no area absorbs stay: ($plan.kept | str join ', ')" }
    print "`honeycomb sidebar --apply` writes it while the Claude desktop app is closed."
    return
  }
  if $config == (claude-config) and (claude-running) {
    error make --unspanned { msg: "Quit the Claude desktop app first: it writes its sidebar back on exit." }
  }
  let backup = (write-sidebar $config $plan)
  print $"Refiled the sidebar; the old one is in ($backup)."
}

# Write a planned sidebar into the app's config, keeping a copy of the old
# file; returns the copy's path.
def write-sidebar [config: path, plan: record] {
  let backup = $"($config).(date now | format date '%Y%m%dT%H%M%S').honeycomb"
  cp $config $backup
  let data = (open $config)
  let prefs = ($data.preferences.epitaxyPrefs | upsert "dframe-code-sections" $plan.sections | upsert "dframe-group-scopes" $plan.scopes)
  $data | upsert preferences ($data.preferences | upsert epitaxyPrefs $prefs) | to json --indent 2 | save --force $config
  $backup
}

# A planned sidebar with one session moved into an area's section, at the
# top of it.
def file-session [plan: record, areas: list, session: record, area: string] {
  let title = ($areas | where name == $area | get 0?.title)
  if $title == null { error make --unspanned { msg: $"no area named ($area)" } }
  let scopes = ($plan.scopes | columns | each {|name|
    let scope = ($plan.scopes | get $name)
    let target = ($scope.groups | where name == $title | get 0?.id)
    if $target == null or not ($session.file | str contains $"/($name)/") { return { $name: $scope } }
    let order = ($scope.order | columns | each {|id|
      let keys = ($scope.order | get $id | where {|key| $key != $session.key })
      { $id: (if $id == $target { $keys | prepend $session.key } else { $keys }) }
    } | to-record)
    { $name: ($scope | upsert assignments ($scope.assignments | upsert $session.key $target) | upsert order $order) }
  } | to-record)
  $plan | upsert scopes $scopes
}

# Apply actions queued on the phone: `archive` a session, or `file` it into
# an area. They wait, unapplied, while the Claude desktop app runs on its
# own config. Returns each applied action's outcome.
def apply-actions [actions: list, config: path, root: path, areas: list] {
  if ($actions | is-empty) { return [] }
  if $config == (claude-config) and (claude-running) { return [] }
  let sessions = (claude-sessions $root)
  mut plan = (plan-from $config $root $areas)
  mut results = []
  mut filed = false
  for action in $actions {
    let session = ($sessions | where key == ($action.target? | default "") | get 0?)
    if $session == null {
      $results = ($results | append { id: $action.id, ok: false, note: "no such session" })
      continue
    }
    if $action.kind == "archive" {
      open $session.file | upsert isArchived true | to json --indent 2 | save --force $session.file
      $results = ($results | append { id: $action.id, ok: true, note: "" })
    } else if $action.kind == "file" {
      let moved = (try { file-session $plan $areas $session ($action.area? | default "") } catch {|error| { failed: $error.msg } })
      if "failed" in ($moved | columns) {
        $results = ($results | append { id: $action.id, ok: false, note: $moved.failed })
      } else {
        $plan = $moved
        $filed = true
        $results = ($results | append { id: $action.id, ok: true, note: "" })
      }
    } else {
      $results = ($results | append { id: $action.id, ok: false, note: $"unknown action ($action.kind)" })
    }
  }
  if $filed { write-sidebar $config $plan | ignore }
  $results
}

# An area's knowledge-base hub, `<range>-<hub>.md`, or the index for Home:
# each top-level bullet, named by its first link or its text.
def hub-notes [kb: path, hub: string] {
  let file = if $hub == "index" { $kb | path join index.md } else { glob ($kb | path join $"[0-9][0-9]-[0-9][0-9]-($hub).md") | get 0? }
  if $file == null or not ($file | path exists) { return [] }
  open --raw $file | lines | where {|line| $line starts-with "- " } | each {|line|
    let linked = ($line | parse --regex '\[(?<title>[^\]]+)\]' | get 0?.title)
    let text = ($line | str substring 2.. | split row " — " | first | str replace --all "`" "")
    { title: ($linked | default $text | str substring 0..59) }
  }
}

# Open luvus tasks with their area and what each changed from trunk.
def task-items [areas: list] {
  if (which luvus | is-empty) { return [] }
  let listed = (^luvus task list | complete)
  if $listed.exit_code != 0 { return [] }
  let tasks = (try { $listed.stdout | from json | get result.tasks } catch { [] })
  $tasks | where status in [queued running review blocked] | each {|task|
    let tree = ($task.worktree? | default "")
    let files = if $tree != "" and ($tree | path exists) {
      let base = (^git -C $tree merge-base HEAD origin/main | complete | get stdout | str trim)
      if $base == "" { [] } else {
        ^git -C $tree diff --numstat $base | complete | get stdout | lines | parse "{added}\t{removed}\t{path}"
      }
    } else { [] }
    {
      area: (folder-area $areas ($task.project?.root? | default ""))
      id: $task.id
      title: $task.title
      status: $task.status
      branch: ($task.branch? | default "")
      files: ($files | first 36)
      changed: ($files | length)
    }
  }
}

# Windows on each area's niri workspace, when niri runs.
def window-items [] {
  if (which niri | is-empty) { return [] }
  let workspaces = (^niri msg --json workspaces | complete)
  let windows = (^niri msg --json windows | complete)
  if $workspaces.exit_code != 0 or $windows.exit_code != 0 { return [] }
  let names = ($workspaces.stdout | from json | where name != null | select id name)
  $windows.stdout | from json | each {|window|
    { area: ($names | where id == $window.workspace_id | get 0?.name), id: $window.id, title: ($window.title? | default ""), app: ($window.app_id? | default "") }
  } | where area != null
}

# Up to 36 of a kind, most relevant first, and how many there are.
def kind [items: list] { { total: ($items | length), items: ($items | first 36) } }

# What each area holds now, for the phone: Claude's live sessions, luvus's
# open tasks, the windows on its niri workspace and its knowledge-base hub.
def flower-snapshot [config: path, root: path, areas: list, kb: path] {
  let sessions = if ($config | path exists) {
    ranked (plan-from $config $root $areas).sessions | each {|session|
      { area: $session.area, id: $session.key, title: $session.title, active: $session.active, gone: $session.gone, link: $session.link }
    }
  } else { [] }
  let tasks = (task-items $areas)
  let windows = (window-items)
  {
    version: 1
    limit: $limit
    generated: (date now | format date "%+")
    host: (sys host | get hostname)
    areas: ($areas | each {|area|
      {
        name: $area.name
        title: $area.title
        cell: $area.cell
        kinds: {
          sessions: (kind ($sessions | where area == $area.name | reject area))
          tasks: (kind ($tasks | where area == $area.name | reject area))
          windows: (kind ($windows | where area == $area.name | reject area))
          notes: (kind (hub-notes $kb $area.hub))
        }
      }
    })
    unfiled: {
      sessions: (kind ($sessions | where area == unfiled | reject area))
      tasks: (kind ($tasks | where area == null | reject area))
    }
  }
}

# The snapshot the phone shows: what each area holds now (see
# flower-snapshot), as JSON.
def "main flower" [
  --config: path # The desktop app's config (default: its own).
  --root: path # Where its sessions are kept (default: its own).
  --areas: path # The areas (default: $env.HONEYCOMB_AREAS).
  --kb: path # The knowledge base (default: $env.KB_ROOT, else ~/kb).
] {
  let kb = ($kb | default ($env.KB_ROOT? | default ($env.HOME | path join kb)))
  flower-snapshot ($config | default (claude-config)) ($root | default (claude-root)) (areas $areas) $kb | to json
}

# Apply a JSON list of queued actions, as `hub sync` does, and print each
# outcome as JSON.
def "main hub apply" [
  actions: path # The actions, as the hub queues them.
  --config: path # The desktop app's config (default: its own).
  --root: path # Where its sessions are kept (default: its own).
  --areas: path # The areas (default: $env.HONEYCOMB_AREAS).
] {
  apply-actions (open $actions) ($config | default (claude-config)) ($root | default (claude-root)) (areas $areas) | to json
}

# Send the hub (lib/honeycomb/runtime/hub) this host's snapshot, apply the
# actions queued on the phone, and report their outcomes. An unreachable
# hub is not an error: the phone keeps the last snapshot.
def "main hub sync" [
  --url: string # The hub (default: $env.HONEYCOMB_HUB).
  --config: path # The desktop app's config (default: its own).
  --root: path # Where its sessions are kept (default: its own).
  --areas: path # The areas (default: $env.HONEYCOMB_AREAS).
  --kb: path # The knowledge base (default: $env.KB_ROOT, else ~/kb).
] {
  let url = ($url | default ($env.HONEYCOMB_HUB? | default ""))
  if $url == "" { error make --unspanned { msg: "no hub: set HONEYCOMB_HUB or pass --url" } }
  let config = ($config | default (claude-config))
  let root = ($root | default (claude-root))
  let areas = (areas $areas)
  let kb = ($kb | default ($env.KB_ROOT? | default ($env.HOME | path join kb)))
  let send = {|results|
    { flower: (flower-snapshot $config $root $areas $kb), results: $results } | to json
    | http post --content-type application/json $"($url)/api/sync" $in
  }
  let reply = (try { do $send [] } catch {|error| { unreachable: $error.msg } })
  if ($reply | describe | str starts-with "record") and "unreachable" in ($reply | columns) {
    print $"hub unreachable: ($reply.unreachable)"
    return
  }
  let pending = ($reply.pending? | default [])
  let results = (apply-actions $pending $config $root $areas)
  # Report the outcomes, with a snapshot that shows them, at once rather
  # than at the next sync.
  if ($results | is-not-empty) {
    let reported = (try { do $send $results; true } catch {|error| print $"hub unreachable: ($error.msg)"; false })
    if not $reported { return }
  }
  print $"synced; applied ($results | where ok | length), failed ($results | where not ok | length), waiting (($pending | length) - ($results | length))"
}

# Each area's live Claude sessions, with the ones to archive: those whose
# directory is gone, and those past the sixth most recently active in their
# area. --archive archives them, with the Claude desktop app closed.
def "main sessions" [
  --archive # Archive the sessions listed for archiving.
  --json # Print every live session as JSON.
  --config: path # The desktop app's config (default: its own).
  --root: path # Where its sessions are kept (default: its own).
  --areas: path # The areas (default: $env.HONEYCOMB_AREAS).
] {
  let config = ($config | default (claude-config))
  let root = ($root | default (claude-root))
  let areas = (areas $areas)
  let live = (ranked (plan-from $config $root $areas).sessions)
  let retire = ($live | where {|session| $session.gone or $session.beyond })
  if $json { return ($live | reject file | to json) }
  if not $archive {
    print (per-area $areas $live | each {|row| $"($row.title): ($row.live) live" } | str join "\n")
    if ($retire | is-empty) { print "\nEvery area holds six or fewer live sessions."; return }
    print $"\nTo archive \(($retire | length)\):"
    print ($retire | each {|session|
      let when = ($session.active * 1_000_000 | into datetime | format date "%Y-%m-%d")
      $"  ($session.area | fill --width 9) ($when) (if $session.gone { 'gone  ' } else { 'past 6' }) ($session.title | str substring 0..44)"
    } | str join "\n")
    print "\n`honeycomb sessions --archive` archives them while the Claude desktop app is closed."
    return
  }
  if $root == (claude-root) and (claude-running) {
    error make --unspanned { msg: "Quit the Claude desktop app first: it writes its sessions back on exit." }
  }
  $retire | each {|session| open $session.file | upsert isArchived true | to json --indent 2 | save --force $session.file } | ignore
  print $"Archived ($retire | length) sessions."
}

def main [] {
  print "Usage: honeycomb (census [--json] | prune [--yes] | sidebar [--apply] | sessions [--archive] | flower | hub sync | hub apply ACTIONS)"
}
