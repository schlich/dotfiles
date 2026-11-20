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

def section [id: string, kind: string, name: string] {
  {
    id: $id, kind: $kind, v: 2, name: $name, order: 0, sortBy: recency, ascending: false
    show: { metadata: false, emptyGroups: false, sideChats: false, slack: true }
    collapsed: false, shown: true
  }
}

def main [script: path, areas: path] {
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

  if ($failures | is-not-empty) {
    print $"\n($failures | length) failed"
    exit 1
  }
}
