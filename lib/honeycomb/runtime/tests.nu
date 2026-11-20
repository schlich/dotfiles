# `honeycomb sidebar` and `honeycomb sessions` on a fixture of the Claude
# desktop app's sidebar and sessions:
#   nu --no-config-file lib/honeycomb/runtime/tests.nu lib/honeycomb/runtime/honeycomb.nu AREAS.json

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

# The hub's handler, run with `http-nu eval` on requests as Tailscale Serve
# passes them on.
def hub-tests [server: path, http_nu: path, home: path] {
  let state = ($home | path join hub)
  mkdir $state
  let probe = ($home | path join hub-probe.nu)
  r#'
    let handler = source SERVER
    let who = { tailscale-user-login: owner }
    let anon = (do $handler { method: GET, path: /api/flower, headers: {} })
    let queued = ('{"kind":"archive","target":"code:local_x"}' | do $handler { method: POST, path: /api/actions, headers: $who })
    let other = ('{"kind":"file","target":"code:local_y","area":"xr"}' | do $handler { method: POST, path: /api/actions, headers: $who })
    let refused = ('{"kind":"delete","target":"x"}' | do $handler { method: POST, path: /api/actions, headers: $who })
    let unfiled = ('{"kind":"file","target":"x"}' | do $handler { method: POST, path: /api/actions, headers: $who })
    do $handler { method: DELETE, path: $"/api/actions/($other.id)", headers: $who } | ignore
    let before = (do $handler { method: GET, path: /api/flower, headers: $who })
    let results = { flower: { version: 1 }, results: [{ id: $queued.id, ok: false, note: busy }] }
    let sync = ($results | to json | do $handler { method: POST, path: /api/sync, headers: $who })
    let after = (do $handler { method: GET, path: /api/flower, headers: $who })
    {
      anon: $anon
      queued: $queued.by
      refused: ($refused.error? != null)
      unfiled: ($unfiled.error? != null)
      before: ($before.pending | length)
      sync: ($sync.pending | length)
      flower: $after.flower.version
      failed: ($after.failed | get note)
    } | to json
  '# | str replace SERVER ($server | path expand | to nuon) | save --force $probe
  let run = (with-env { HUB_STATE: $state } { ^$http_nu eval $probe | complete })
  if $run.exit_code != 0 { print $run.stderr; return ["the hub's handler runs"] }
  let got = ($run.stdout | from json)
  [
    (expect "the hub refuses a request that did not come through Serve" $got.anon "Reach the hub through Tailscale Serve.")
    (expect "the hub records who queued an action" $got.queued owner)
    (expect "the hub refuses an unknown action" $got.refused true)
    (expect "the hub refuses filing without an area" $got.unfiled true)
    (expect "a dropped action leaves the queue" $got.before 1)
    (expect "a sync settles the actions it reports" $got.sync 0)
    (expect "a sync stores the snapshot" $got.flower 1)
    (expect "a failed action is kept with its reason" $got.failed [busy])
  ] | flatten
}

def section [id: string, kind: string, name: string] {
  {
    id: $id, kind: $kind, v: 2, name: $name, order: 0, sortBy: recency, ascending: false
    show: { metadata: false, emptyGroups: false, sideChats: false, slack: true }
    collapsed: false, shown: true
  }
}

def main [
  script: path # honeycomb.nu
  areas: path # The areas as JSON.
  server?: path # hub/server.nu, to test the hub as well
  http_nu?: path # The http-nu binary that runs it.
] {
  let script = ($script | path expand)
  let areas = ($areas | path expand)
  let home = ($env.HOME | path expand)
  # Not the app's own directory, so the commands write without checking that
  # the app is closed.
  let root = ($home | path join fixture Claude)
  let scope = "acct/org"
  let store = ($root | path join claude-code-sessions acct org)
  mkdir $store
  for folder in [dotfiles kb elsewhere game] { mkdir ($home | path join $folder) }

  # key, directory under $HOME, archived, last activity, section
  let sessions = [
    [id folder archived active group];
    [a dotfiles false 100 cg-hosts]
    [b kb false 100 null]
    [c elsewhere false 100 null]
    [d dotfiles false 100 cg-ci]
    [e dotfiles false 100 cg-friends]
    [f dotfiles false 100 cg-mystery]
    [g gone false 100 cg-desktop]
    [h game true 50 cg-agents]
    [i game false 60 null]
  ] | append (1..7 | each {|n| { id: $"n($n)", folder: dotfiles, archived: false, active: $n, group: null } })
  for session in $sessions {
    {
      sessionId: $"local_($session.id)"
      cwd: ($home | path join $session.folder)
      isArchived: $session.archived
      lastActivityAt: $session.active
      title: $"session ($session.id)"
      bridgeSessionIds: (if $session.id == "a" { [session_old session_a] } else { [] })
    } | to json | save --force ($store | path join $"local_($session.id).json")
  }
  let groups = [
    { id: cg-hosts, name: "Hosts & Nix", mode: code }
    { id: cg-ci, name: "CI & landing", mode: code }
    { id: cg-friends, name: "Stuff for friends", mode: code }
    { id: cg-mystery, name: "Mystery", mode: code }
    { id: cg-desktop, name: "Desktop & terminal", mode: code }
    { id: cg-agents, name: "Agent tooling", mode: code }
  ]
  let assigned = ($sessions | where group != null | each {|session| { $"code:local_($session.id)": $session.group } } | reduce --fold {} {|it, acc| $acc | merge $it })
  let config = ($root | path join claude_desktop_config.json)
  {
    keep: "untouched"
    preferences: {
      other: 1
      epitaxyPrefs: {
        "dframe-code-sections": { $scope: { sections: (
          [(section pinned pinned "") (section routines routines "")]
          | append ($groups | each {|group| section $group.id manual $group.name | insert members [] })
          | append [(section sessions sessions "")]
        ) } }
        "dframe-group-scopes": { $scope: { groups: $groups, assignments: $assigned, order: { cg-ci: ["code:local_d"], cg-hosts: ["code:local_a"] } } }
      }
    }
  } | to json | save --force $config

  let planned = (^nu --no-config-file $script sidebar --json --config $config --root $root --areas $areas | complete)
  if $planned.exit_code != 0 { print $planned.stderr; exit 1 }
  let plan = ($planned.stdout | from json)
  let sections = ($plan.sections | get $scope | get sections)
  let scope_plan = ($plan.scopes | get $scope)
  let id_of = {|name| $scope_plan.groups | where name == $name | get 0.id }
  let group_of = {|session| $scope_plan.assignments | get --optional $"code:local_($session)" }
  let failures = [
    (expect "the sidebar is pinned, routines, the seven areas, kept sections, then the unfiled list" ($sections | get name) ["" "" Home Work Research Nix "AI & agents" XR Life Mystery ""])
    (expect "sections are numbered in order" ($sections | get order) (0..10 | each { $in }))
    (expect "an area reuses the first section it absorbs" (do $id_of Nix) cg-hosts)
    (expect "a section an area absorbs moves into it" (do $group_of d) cg-hosts)
    (expect "the absorbed section's order carries over" ($scope_plan.order | get cg-hosts | first 2) ["code:local_a" "code:local_d"])
    (expect "a section no area absorbs keeps its sessions" (do $group_of f) cg-mystery)
    (expect "an unfiled session joins its folder's area" (do $group_of b) (do $id_of Research))
    (expect "an unfiled session joins the area its project's sessions are in" (do $group_of i) cg-agents)
    (expect "a session with no area stays unfiled" (do $group_of c) null)
    (expect "a new area gets a section of its own" ((do $id_of Work) | str starts-with "cg-") true)
    (expect "absorbed sections are gone" ($scope_plan.groups | get name | where $it in ["Hosts & Nix" "CI & landing"]) [])
  ] | flatten

  let listed = (^nu --no-config-file $script sessions --json --config $config --root $root --areas $areas | complete)
  if $listed.exit_code != 0 { print $listed.stderr; exit 1 }
  let live = ($listed.stdout | from json)
  let nix = ($live | where area == nix | sort-by active --reverse)
  let failures = $failures | append ([
    (expect "archived sessions are not counted" ($live | where title == "session h") [])
    (expect "a session whose directory is gone is marked" ($live | where gone | get title) ["session g"])
    (expect "nix keeps its six most recently active" ($nix | where not beyond | length) 6)
    (expect "the rest of nix is past six" ($nix | where beyond | get title) ["session n3" "session n2" "session n1"])
  ] | flatten)

  # Applying writes the plan and keeps everything else in the file.
  let applied = (^nu --no-config-file $script sidebar --apply --config $config --root $root --areas $areas | complete)
  let written = (open $config)
  let failures = $failures | append ([
    (expect "--apply writes a config that is not the app's own" $applied.exit_code 0)
    (expect "--apply keeps the rest of the file" [$written.keep $written.preferences.other] ["untouched" 1])
    (expect "--apply writes the sections" ($written.preferences.epitaxyPrefs."dframe-code-sections" | get $scope | get sections | get name) ($sections | get name))
    (expect "--apply keeps a backup" (glob $"($config).*.honeycomb" | length) 1)
  ] | flatten)

  let archived = (^nu --no-config-file $script sessions --archive --config $config --root $root --areas $areas | complete)
  let failures = $failures | append ([
    (expect "--archive archives the marked sessions" (["g" "n1" "n2" "n3"] | each {|id| open ($store | path join $"local_($id).json") | get isArchived }) [true true true true])
    (expect "--archive leaves the rest" (open ($store | path join local_a.json) | get isArchived) false)
  ] | flatten)

  # The phone's snapshot: live sessions and hub notes by area.
  let kb = ($home | path join kb)
  "# Nix\n\n- [Alpha](alpha.md) — the first\n- plain `code` — the second\n  - nested, not listed\n" | save --force ($kb | path join 40-49-nix.md)
  let snapshot = (^nu --no-config-file $script flower --config $config --root $root --areas $areas --kb $kb | complete)
  if $snapshot.exit_code != 0 { print $snapshot.stderr; exit 1 }
  let flower = ($snapshot.stdout | from json)
  let nix_area = ($flower.areas | where name == nix | get 0)
  let failures = $failures | append ([
    (expect "the snapshot lists the seven areas in order" ($flower.areas | get name) [home work research nix ai xr life])
    (expect "an area counts its live sessions" $nix_area.kinds.sessions.total 6)
    (expect "a Remote Control session links to claude.ai" ($nix_area.kinds.sessions.items | where id == "code:local_a" | get 0.link) "https://claude.ai/code/session_a")
    (expect "an area lists its hub's top-level notes" ($nix_area.kinds.notes.items | get title) ["Alpha" "plain code"])
    (expect "sessions with no area are unfiled" ($flower.unfiled.sessions.items | get id | sort) ["code:local_c" "code:local_f"])
  ] | flatten)

  # Actions queued on the phone.
  let actions = ($home | path join actions.json)
  [
    { id: "1", kind: archive, target: "code:local_d" }
    { id: "2", kind: file, target: "code:local_c", area: xr }
    { id: "3", kind: file, target: "code:local_missing", area: xr }
    { id: "4", kind: file, target: "code:local_a", area: nowhere }
  ] | to json | save --force $actions
  let applied = (^nu --no-config-file $script hub apply $actions --config $config --root $root --areas $areas | complete)
  if $applied.exit_code != 0 { print $applied.stderr; exit 1 }
  let outcomes = ($applied.stdout | from json)
  let scope_now = (open $config | get preferences.epitaxyPrefs."dframe-group-scopes" | get $scope)
  let xr = ($scope_now.groups | where name == XR | get 0.id)
  let failures = $failures | append ([
    (expect "each action has an outcome" ($outcomes | get ok) [true true false false])
    (expect "a missing session is reported" ($outcomes | get 2.note) "no such session")
    (expect "archiving archives the session" (open ($store | path join local_d.json) | get isArchived) true)
    (expect "filing assigns the session to the area" ($scope_now.assignments | get "code:local_c") $xr)
    (expect "filing puts the session first in its section" ($scope_now.order | get $xr | first) "code:local_c")
  ] | flatten)

  let failures = $failures | append (if $server == null { [] } else { hub-tests $server $http_nu $home })

  if ($failures | is-not-empty) {
    print $"\n($failures | length) failed"
    exit 1
  }
}
