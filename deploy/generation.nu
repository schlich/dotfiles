# Say which system and Home Manager generation this host runs, and which
# commit each came from. A store path does not name its commit: stamping it
# in, as system.configurationRevision does, would change the closure on every
# landing, so a refactor could no longer prove it changes nothing and every
# landing would warrant a generation. Instead nixos-switch-main pairs each
# store path it deploys or finds already running with its revision in
# generations.jsonl, and home-activate keeps the same record for each
# standalone Home Manager generation it builds from a working copy.

const SYSTEM = '/nix/var/nix/profiles/system'

# Where nixos-switch-main keeps its logs; DEPLOY_STATE points elsewhere for a
# trial run.
def state [] { $env.DEPLOY_STATE? | default '/var/lib/nixos-switch-main' }

def home-state [] { $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) }

def entries [log: string] {
    if not ($log | path exists) { return [] }
    open --raw $log | lines | where $it != '' | each { from json }
}

def resolve [link: string] {
    if ($link | path exists) { ^readlink --canonicalize $link | str trim } else { null }
}

# The newest generation of a profile whose link points at a store path.
def generation-of [profile: string, target] {
    if $target == null { return null }
    let pattern = ('^' + ($profile | path basename) + '-(?<n>\d+)-link$')
    ls --long ($profile | path dirname)
    | where type == symlink and target == $target
    | each {|link| $link.name | path basename | parse --regex $pattern }
    | flatten
    | get --optional n
    | default []
    | each { into int }
    | sort
    | last 1
    | get 0?
}

# The revision that first produced a store path, and the newest one recorded
# as still producing it, since a refactor lands without changing it.
def system-source [rows: list] {
    if ($rows | is-empty) { return null }
    let first = ($rows | first)
    let newest = ($rows | last)
    {
        rev: $first.rev
        release: $first.release
        subject: $first.subject
        at: $first.at
        matches_through: (if $newest.rev == $first.rev { null } else { $newest | select rev subject at })
    }
}

# Whether GitHub's main is a revision recorded for the running system.
# `ahead` means this host has not yet been switched to or checked against
# it; whether it changes this host is known only once a switch evaluates it.
def main-state [rows: list] {
    let repo = ($env.DEPLOY_REPO? | default '')
    if ($repo | is-empty) { return null }
    let result = (^timeout 5 git ls-remote $repo refs/heads/main | complete)
    let rev = ($result.stdout | lines | get 0? | default '' | split row "\t" | first)
    if $result.exit_code != 0 or ($rev | is-empty) { return { rev: null, state: unreachable } }
    let state = if ($rows | is-empty) { 'unknown' } else if $rev in ($rows | get rev) { 'current' } else { 'ahead' }
    { rev: $rev, state: $state }
}

# The running standalone Home Manager generation, and the change it came
# from when home-activate built it; a bare `nh home switch` leaves none.
def home [] {
    let profile = (home-state | path join nix profiles home-manager)
    let running = (resolve $profile)
    if $running == null { return null }
    let activated = (entries (home-state | path join home-activate generations.jsonl) | where activation == $running | last 1 | get 0?)
    {
        generation: (generation-of $profile $running)
        path: $running
        origin: (if $activated != null { 'home-activate' } else { 'unrecorded' })
        source: (if $activated == null { null } else { $activated | reject activation })
    }
}

def summary [report: record] {
    let system = $report.system
    let staging = if $system.staged { ' staging' } else if $system.boot_default != $system.generation { $" boot ($system.boot_default)" } else { '' }
    let source = if $report.source == null { ' @ unrecorded' } else {
        let release = if ($report.source.release | is-empty) { '' } else { $" ($report.source.release)" }
        $" @ ($report.source.rev | str substring 0..7)($release)"
    }
    let main = if $report.main?.state? == 'ahead' { ' · main ahead' } else { '' }
    let home = if $report.home == null { '' } else {
        let from = match $report.home.origin {
            'home-activate' => $" from ($report.home.source.change)(if $report.home.source.landed { '' } else { ' unlanded' })"
            _ => ' unrecorded'
        }
        $" · hm ($report.home.generation)($from)"
    }
    $"($report.host) gen ($system.generation)($staging)($source)($main)($home)"
}

# Show the running generation and the commit it came from.
def main [
    --json # print the report as JSON
    --line # print one line, for a status bar or prompt
    --offline # do not ask GitHub where main is
] {
    let running = (resolve /run/current-system)
    let generation = (generation-of $SYSTEM $running)
    let rows = (entries ((state) | path join generations.jsonl) | where toplevel == $running)
    let report = {
        host: (sys host | get hostname)
        system: {
            generation: $generation
            path: $running
            booted: (generation-of $SYSTEM (resolve /run/booted-system))
            boot_default: (generation-of $SYSTEM (resolve $SYSTEM))
            staged: ((state) | path join pending.nuon | path exists)
        }
        source: (system-source $rows)
        main: (if $offline { null } else { main-state $rows })
        home: (home)
    }
    if $json { return ($report | to json) }
    if $line { return (summary $report) }
    $report | table --expand
}
