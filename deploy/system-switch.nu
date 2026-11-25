# Apply the NixOS configuration on GitHub's main without sudo: start the
# root nixos-switch-main unit, follow its step reports as it runs, then
# print a structured Nushell summary (or JSON with --json). Pass --verbose
# to stream the raw systemd journal and Home Manager output as they arrive.
# modules/nixos/fleet/system-switch.nix wraps this with DEPLOY_UNIT,
# DEPLOY_STATE, DEPLOY_REPO, DEPLOY_HOST, DEPLOY_FLEET, DEPLOY_GIT, and
# DEPLOY_NIX.
#
# deploy/switch.nu writes a JSON line to `status.jsonl` in the state
# directory for each step, tagged with the unit run's invocation. When
# PST_FILE is set, as a `job-log` job sets it, each of this run's reports,
# and the build's progress counted from nix's own lines, is appended there
# as osc7501.nu's `pst report` would, so a job watcher sees every step as it
# happens rather than the whole journal at the end.
#
# Live progress lines go to stderr so stdout carries only the structured
# summary (table by default, JSON with --json), making
# `system-switch --json | from json` work cleanly in Nushell pipelines.
#
# The journal is read through the user manager, which writes it to a file
# under ~/.cache, so this also works inside the Claude desktop app's sandbox.
#
# A system that stops embedding Home Manager takes the user's packages with
# it: on 2026-10-19 the first asus switch after the home went standalone
# emptied /etc/profiles/per-user, and nothing had populated ~/.nix-profile.
# So before starting the unit, a running system that still activates this
# user's home is checked against main: when main builds that home as
# homeConfigurations."USER@HOST" and it is not the active home generation,
# this stops unless --with-home asks to activate that home, from the commit
# the switch deployed, once the switch succeeds.
#
# A host whose inventory embeds the user's home (homeActivation =
# "embedded", as on homelab) activates it with the system, so there is no
# gap to guard, and --with-home only notes that the switch included it.
#
# `system-switch HOST` names the host to switch, so the command means the
# same wherever it runs: on HOST it switches here, and elsewhere it runs
# `system-switch` on HOST over ssh, at the destination DEPLOY_FLEET gives
# for it (den/aspects/fleet/deploy-policy.nix), and forwards that run's step
# reports to PST_FILE. Without a host it switches this one.

const BIN = '/run/current-system/sw/bin'
const APP = 'nixos-switch-main'
const SYSTEM_PROFILE = '/nix/var/nix/profiles/system'

def unit [] { $"($env.DEPLOY_UNIT).service" }

def show [property: string]: nothing -> string {
    ^$"($BIN)/systemctl" show (unit) --property $property --value | complete | get stdout | str trim
}

# Append a report to PST_FILE, when one is set.
def forward [report: record] {
    if ($env.PST_FILE? | is-empty) { return }
    let report = ({ time: (date now | format date '%+') } | merge $report)
    try { $"($report | to json --raw)\n" | save --append $env.PST_FILE }
}

# The complete lines `file` gained past byte `offset`, and the offset after
# them. A file that shrank was started afresh, so it is read from the top. A
# last line still being written waits for its newline, unless --final says
# nothing more will be written.
def read-new [file: path, offset: int, --final]: nothing -> record {
    if not ($file | path exists) { return { lines: [], offset: 0 } }
    let bytes = (open --raw $file | into binary)
    let offset = if ($bytes | bytes length) < $offset { 0 } else { $offset }
    let chunk = ($bytes | bytes at $offset..)
    let end = if $final { $chunk | bytes length } else { ($chunk | bytes index-of --end 0x[0a]) + 1 }
    { lines: ($chunk | bytes at ..<$end | decode utf-8 | lines), offset: ($offset + $end) }
}

# Whole seconds in Nushell's duration format (`47sec`, `1min 14sec`).
def format-duration [dur: duration]: nothing -> string {
    let secs = if $dur < 0sec { 0sec } else { ($dur // 1sec) * 1sec }
    $secs | into string
}

def short-rev [rev: any]: nothing -> string {
    if $rev == null { '' } else { $rev | into string | str substring 0..<12 }
}

def step-name [id: string]: nothing -> string {
    $id | str replace --regex '^switch/' ''
}

def strip-store [text: string]: nothing -> string {
    $text | ansi strip | str replace --all --regex '/nix/store/[0-9a-z]{32}-' ''
}

# What nix said it will build and fetch, and how far it has got, from the
# lines it writes without a terminal.
def tally [build: record, line: string]: nothing -> record {
    let line = ($line | ansi strip)
    let count = {|| $line | parse --regex '^these (?<n>\d+)' | get n.0 | into int }
    if $line =~ '^these \d+ derivations will be built' {
        $build | update builds (do $count)
    } else if $line =~ '^this derivation will be built' {
        $build | update builds 1
    } else if $line =~ '^these \d+ paths will be fetched' {
        $build | update fetches (do $count)
    } else if $line =~ '^this path will be fetched' {
        $build | update fetches 1
    } else if $line =~ r#'^building '/nix/store/'# {
        let name = ($line | parse --regex r#'^building '/nix/store/[0-9a-z]{32}-(?<name>.+?)\.drv''# | get name.0? | default '')
        $build | update built { $in + 1 } | update current $name
    } else if $line =~ r#'^copying path '/nix/store/'# {
        $build | update fetched { $in + 1 }
    } else {
        $build
    }
}

# The build's progress as a report: the derivation being built, and how many
# of the announced builds and downloads have started.
def build-report [build: record]: nothing -> record {
    let total = ($build.builds + $build.fetches)
    let parts = (
        (if $build.builds > 0 { [$"build ($build.built)/($build.builds)(if ($build.current | is-empty) { '' } else { $': ($build.current)' })"] } else { [] })
        ++ (if $build.fetches > 0 { [$"fetched ($build.fetched)/($build.fetches)"] } else { [] })
    )
    let progress = if $total == 0 { 0 } else { [((($build.built + $build.fetched) * 100) // $total) 99] | math min }
    { state: working, id: switch/build, app: $APP, msg: ($parts | str join '; '), progress: $progress }
}

def build-detail [build: record]: nothing -> string {
    let parts = (
        (if $build.builds > 0 {
            let n = if $build.built > 0 { $build.built } else { $build.builds }
            [$"($n) built"]
        } else { [] })
        ++ (if $build.fetches > 0 {
            let n = if $build.fetched > 0 { $build.fetched } else { $build.fetches }
            [$"($n) fetched"]
        } else { [] })
    )
    $parts | str join ', '
}

def parse-switch-header [msg: string]: nothing -> record {
    let parsed = ($msg | ansi strip | parse --regex '^Switching (?<host>\S+) to main at (?<rev>[0-9a-f]+)(?:: (?<subject>.+))?$' | get 0?)
    if $parsed == null { {} } else {
        {
            host: $parsed.host
            rev: $parsed.rev
            subject: ($parsed.subject? | default '' | str trim)
        }
    }
}

def start-detail [id: string, msg: string]: nothing -> string {
    let clean = (strip-store $msg | str trim)
    match $id {
        'switch/evaluate' => ''
        'switch/preview' => ''
        'switch/activate' => ''
        'switch/commit' => ''
        'switch/build' => ($clean | parse --regex '(?<free>\S+ free on /nix)' | get free.0? | default '')
        _ => $clean
    }
}

def step-detail [id: string, state: string, msg: string, build: record]: nothing -> string {
    let clean = (strip-store $msg | str trim)
    if $state == 'error' { return $clean }
    match $id {
        'switch/evaluate' => ''
        'switch/build' => (build-detail $build)
        'switch/preview' => {
            let m = ($clean | parse --regex '(?<n>\d+) units? to settle' | get n.0?)
            if $m == null { '' } else {
                let n = ($m | into int)
                if $n == 1 { '1 unit' } else { $"($n) units" }
            }
        }
        'switch/activate' => ''
        'switch/watch' => ''
        'switch/commit' => ''
        _ => $clean
    }
}

def format-step-line [kind: string, step: string, took: string = '', msg: string = '']: nothing -> string {
    let suffix = if ($msg | is-empty) { '' } else { $": ($msg)" }
    let dur = if ($took | is-empty) { '' } else { $" (ansi dark_gray)\(($took)\)(ansi reset)" }
    match $kind {
        'working' => $"(ansi cyan)▶(ansi reset) ($step)($suffix)"
        'update' => $"(ansi dark_gray)  · ($step)($suffix)(ansi reset)"
        'done' => $"(ansi green)✓(ansi reset) ($step)($dur)($suffix)"
        'error' => $"(ansi red)✗(ansi reset) ($step)($dur)($suffix)"
        _ => $"(ansi dark_gray)· ($step)($suffix)(ansi reset)"
    }
}

def empty-tracker []: nothing -> record {
    { starts: {}, steps: [], subject: '', last_msg: {} }
}

# Fold one status.jsonl report into the step tracker and return the concise
# progress line to print on stderr (or null when nothing new should print).
def record-step [tracker: record, report: record, build: record]: nothing -> record {
    let at = (try { $report.time | into datetime } catch { date now })
    let id = ($report.id? | default '')
    let state = ($report.state? | default '')
    let msg = ($report.msg? | default '')
    let name = (step-name $id)

    if $id == 'switch' {
        if $state == 'working' {
            let header = (parse-switch-header $msg)
            let subject = ($header.subject? | default '')
            let starts = if ($tracker.starts | get --optional switch) == null {
                $tracker.starts | upsert switch $at
            } else { $tracker.starts }
            let tracker = ($tracker | update starts $starts | update subject (if ($subject | is-not-empty) { $subject } else { $tracker.subject }))
            let label = if ($header.rev? | is-not-empty) {
                $"($header.host) @ ($header.rev)"
            } else { 'switch' }
            let detail = if ($header.rev? | is-not-empty) { $subject } else { strip-store $msg | str trim }
            return { tracker: $tracker, line: (format-step-line working $label '' $detail) }
        }
        if $state == 'error' {
            let started = ($tracker.starts | get --optional switch | default $at)
            let took = (format-duration ($at - $started))
            return { tracker: $tracker, line: (format-step-line error switch $took (strip-store $msg | str trim)) }
        }
        return { tracker: $tracker, line: null }
    }

    if $state == 'working' {
        let existing = ($tracker.starts | get --optional $name)
        if $existing == null {
            let hint = (start-detail $id $msg)
            let tracker = (
                $tracker
                | update starts { upsert $name $at }
                | update last_msg { upsert $name $hint }
            )
            return { tracker: $tracker, line: (format-step-line working $name '' $hint) }
        }
        let clean = (strip-store $msg | str trim)
        let prev = ($tracker.last_msg | get --optional $name | default '')
        if ($clean | is-not-empty) and $clean != $prev {
            let tracker = ($tracker | update last_msg { upsert $name $clean })
            return { tracker: $tracker, line: (format-step-line update $name '' $clean) }
        }
        return { tracker: $tracker, line: null }
    }

    if $state in ['done' 'error'] {
        let started = ($tracker.starts | get --optional $name | default $at)
        let took = (format-duration ($at - $started))
        let detail = (step-detail $id $state $msg $build)
        let row = { step: $name, state: $state, took: $took, detail: $detail }
        let tracker = ($tracker | update steps { append $row })
        return { tracker: $tracker, line: (format-step-line $state $name $took $detail) }
    }

    { tracker: $tracker, line: null }
}

# Units dry-activate said the candidate would start, restart, or reload.
def parse-touched-units [lines: list<string>]: nothing -> list<string> {
    $lines
    | each { ansi strip }
    | parse --regex '^would (?:start|restart|reload) the following units: (?<units>.+)$'
    | get units
    | each { split row ',' | str trim }
    | flatten
    | where $it != ''
    | uniq
}

# Package and closure changes printed by modules/nixos/fleet/closure-diff.nix
# (dix) during activation, as a structured record, or null when no diff ran.
def parse-closure-diff [lines: list<string>]: nothing -> any {
    mut in_diff = false
    mut section = ''
    mut paths = ''
    mut size = ''
    mut note = ''
    mut changed = []
    mut added = []
    mut removed = []

    for raw in $lines {
        let line = ($raw | ansi strip | str trim)
        if $line == 'package changes from the running system:' {
            $in_diff = true
            $section = ''
            $paths = ''
            $size = ''
            $note = ''
            $changed = []
            $added = []
            $removed = []
            continue
        }
        if not $in_diff { continue }
        if ($line | is-empty) or ($line | str starts-with '<<< ') or ($line | str starts-with '>>> ') {
            continue
        }
        if $line =~ '^CHANGED \(\d+\)$' {
            $section = 'changed'
        } else if $line =~ '^ADDED \(\d+\)$' {
            $section = 'added'
        } else if $line =~ '^REMOVED \(\d+\)$' {
            $section = 'removed'
        } else if $line =~ '^PATHS:\s+' {
            $paths = ($line | str replace --regex '^PATHS:\s+' '')
            $section = ''
        } else if $line =~ '^SIZE:\s+' {
            $size = ($line | str replace --regex '^SIZE:\s+' '')
            $section = ''
        } else if $line =~ '^NOTE:\s+' {
            $note = ($line | str replace --regex '^NOTE:\s+' '')
            $in_diff = false
        } else if $section != '' and ($line | str starts-with '[') {
            let m = ($line | parse --regex '^\[[^\]]+\]\s+(?<name>\S+)(?:\s+(?<rest>.+))?$' | get 0?)
            if $m != null {
                let name = $m.name
                let rest = ($m.rest? | default '' | str trim)
                let entry = if ($rest | is-empty) or $rest == '<none>' { $name } else { $"($name) ($rest)" }
                if $section == 'changed' {
                    if not ($name | str starts-with 'nixos-system-') {
                        $changed = ($changed | append $entry)
                    }
                } else if $section == 'added' {
                    $added = ($added | append $entry)
                } else if $section == 'removed' {
                    $removed = ($removed | append $entry)
                }
            }
        } else if ($size | is-not-empty) or ($paths | is-not-empty) {
            $in_diff = false
        }
    }

    if ($paths | is-empty) and ($size | is-empty) and ($changed | is-empty) and ($added | is-empty) and ($removed | is-empty) {
        return null
    }
    mut out = {
        paths: $paths
        size: $size
        changed: $changed
        added: $added
        removed: $removed
    }
    if ($note | is-not-empty) { $out = ($out | insert note $note) }
    $out
}

def parse-failed-units [text: string]: nothing -> list<string> {
    $text
    | lines
    | each { str trim | split row --regex '\s+' | get 0? | default '' }
    | where { is-not-empty }
}

def join-cap [items: list<string>, limit: int = 8]: nothing -> string {
    let count = ($items | length)
    if $count <= $limit {
        $items | str join ', '
    } else {
        $"($items | first $limit | str join ', ') \(+($count - $limit) more\)"
    }
}

def format-home [home: record]: nothing -> string {
    let gen = if $home.generation? != null { $"gen ($home.generation)" } else { '' }
    match ($home.status? | default '') {
        'activated' => {
            let bits = ([$gen ($home.took? | default '')] | where { is-not-empty } | str join ', ')
            if ($bits | is-empty) { 'activated' } else { $"activated \(($bits)\)" }
        }
        'unchanged' => (if ($gen | is-empty) { 'already active' } else { $"already active \(($gen)\)" })
        'embedded' => (if ($gen | is-empty) { 'embedded in system' } else { $"embedded in system \(($gen)\)" })
        'none' => 'none in main'
        'failed' => $"failed: ($home.error? | default 'activation failed')"
        _ => ($home.status? | default '')
    }
}

# Canonical structured summary record (printed directly for --json, and
# compacted by format-summary for terminal tables).
def build-summary [data: record]: nothing -> record {
    let rev = ($data.rev? | default '')
    {
        host: $data.host
        outcome: $data.outcome
        rev: (if ($rev | is-empty) { null } else { $rev })
        short_rev: (short-rev $rev)
        subject: (if ($data.subject? | is-empty) { null } else { $data.subject })
        generation: $data.generation?
        took: $data.took
        steps: ($data.steps? | default [])
        changes: $data.changes?
        units: ($data.units? | default [])
        home: $data.home?
        failed_units: ($data.failed_units? | default [])
        report: (if ($data.report? | is-empty) { null } else { $data.report })
        toplevel: (if ($data.toplevel? | is-empty) { null } else { $data.toplevel })
        at: (if ($data.at? | is-empty) { null } else { $data.at })
    }
}

# Compact record for Nushell's box table: drops null/empty optional fields
# and store paths, joins short lists, and omits empty step details.
def format-summary [summary: record]: nothing -> record {
    mut out = {
        host: $summary.host
        outcome: $summary.outcome
    }
    if ($summary.short_rev | is-not-empty) {
        let rev_cell = if ($summary.subject | is-not-empty) {
            $"($summary.short_rev) — ($summary.subject)"
        } else { $summary.short_rev }
        $out = ($out | insert rev $rev_cell)
    }
    if $summary.generation != null {
        $out = ($out | insert generation $summary.generation)
    }
    $out = ($out | insert took $summary.took)
    if ($summary.steps | is-not-empty) {
        let has_detail = ($summary.steps | any {|r| ($r.detail? | default '' | is-not-empty) })
        let steps = if $has_detail { $summary.steps } else { $summary.steps | reject --optional detail }
        $out = ($out | insert steps $steps)
    }
    if $summary.changes != null {
        let c = $summary.changes
        mut diff = {}
        if ($c.paths? | is-not-empty) { $diff = ($diff | insert paths $c.paths) }
        if ($c.size? | is-not-empty) { $diff = ($diff | insert size $c.size) }
        if ($c.changed? | default [] | is-not-empty) { $diff = ($diff | insert changed (join-cap $c.changed)) }
        if ($c.added? | default [] | is-not-empty) { $diff = ($diff | insert added (join-cap $c.added)) }
        if ($c.removed? | default [] | is-not-empty) { $diff = ($diff | insert removed (join-cap $c.removed)) }
        if ($c.note? | is-not-empty) { $diff = ($diff | insert note $c.note) }
        if ($diff | is-not-empty) { $out = ($out | insert changes $diff) }
    }
    if ($summary.units | is-not-empty) {
        $out = ($out | insert units (join-cap $summary.units))
    }
    if $summary.home != null {
        $out = ($out | insert home (format-home $summary.home))
    }
    if ($summary.failed_units | is-not-empty) {
        $out = ($out | insert failed_units ($summary.failed_units | str join ', '))
    }
    if ($summary.report | is-not-empty) {
        $out = ($out | insert report $summary.report)
    }
    $out
}

def profile-generation [profile: string]: nothing -> any {
    if not ($profile | path exists) { return null }
    let link = (^readlink $profile | complete | get stdout | str trim)
    $link | parse --regex '-(?<n>\d+)-link$' | get n | each { into int } | get 0?
}

def home-name [] { $"($env.USER)@($env.DEPLOY_HOST)" }

def home-state [] { $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) }

def home-profile [] { home-state | path join nix profiles home-manager }

# The store path the user's Home Manager profile points at, or null.
def running-home [] {
    let profile = (home-profile)
    if ($profile | path exists) { ^readlink --canonicalize $profile | str trim } else { null }
}

# Whether the running system still activates this user's home through the
# Home Manager NixOS module, whose unit it names after the user.
def embedded-home [] {
    $"/run/current-system/etc/systemd/system/home-manager-($env.USER).service" | path exists
}

def flake-at [rev: string] { $"git+($env.DEPLOY_REPO)?ref=main&rev=($rev)" }

def main-rev [] {
    let result = (^$env.DEPLOY_GIT ls-remote $env.DEPLOY_REPO refs/heads/main | complete)
    let rev = ($result.stdout | lines | get 0? | default '' | split row "\t" | first | str trim)
    if $result.exit_code != 0 or ($rev | is-empty) {
        error make --unspanned { msg: $"Could not resolve main on ($env.DEPLOY_REPO): ($result.stderr | str trim)" }
    }
    $rev
}

# The activation package `rev` builds as this user's standalone home, or
# null when that revision has none for this user and host.
def standalone-home [rev: string] {
    let flake = (flake-at $rev)
    let name = (home-name)
    let has = (^$env.DEPLOY_NIX eval --json $"($flake)#homeConfigurations" --apply $"homes: homes ? \"($name)\"" | complete)
    if $has.exit_code != 0 {
        error make --unspanned { msg: $"Could not evaluate homeConfigurations at (short-rev $rev): ($has.stderr | lines | last 20 | str join "\n")" }
    }
    if ($has.stdout | str trim) != 'true' { return null }
    let installable = $"($flake)#homeConfigurations.\"($name)\".activationPackage"
    let out = (^$env.DEPLOY_NIX eval --raw $"($installable).outPath" | complete)
    if $out.exit_code != 0 {
        error make --unspanned { msg: $"Could not evaluate ($name)'s home at (short-rev $rev): ($out.stderr | lines | last 20 | str join "\n")" }
    }
    { installable: $installable, path: ($out.stdout | str trim) }
}

# What switching to main would take from this user: null when the running
# system no longer embeds their home, when main does not build it
# standalone, or when main's standalone home is already the active one.
def home-gap [] {
    if not (embedded-home) { return null }
    let rev = (main-rev)
    let home = (standalone-home $rev)
    if $home == null or (running-home) == $home.path { return null }
    { rev: $rev, home: $home }
}

def gap-message [gap: record] {
    let short = (short-rev $gap.rev)
    [
        $"Not switching: main at ($short) runs Home Manager standalone, as homeConfigurations.\"(home-name)\", while the running system still activates ($env.USER)'s home, and main's home is not the active generation."
        "Switching alone would drop every Home Manager package (jj, ci, nh, home-activate, ...) from PATH."
        "Either:"
        "  system-switch --with-home    # switch, then activate main's home from the same commit"
        $"  home-activate                # first, from ~/Nix/dotfiles at main \(($short)\), then system-switch"
    ] | str join "\n"
}

def lookup-subject [rev: string]: nothing -> string {
    if ($rev | is-empty) { return '' }
    let log = ($env.DEPLOY_STATE | path join generations.jsonl)
    try { open --raw $log | lines | where $it != '' | each { from json } | where rev == $rev | last | get subject } catch { '' }
}

# Record a home this command activated where `generation` reads
# home-activate's records.
def record-home [rev: string, activation: string] {
    let gen = (profile-generation (home-profile))
    let subject = (lookup-subject $rev)
    let entry = {
        at: (date now | format date '%+')
        activation: $activation
        generation: $gen
        via: system-switch
        change: null
        commit: (short-rev $rev)
        landed: true
        description: $subject
    }
    let dir = (home-state | path join home-activate)
    try {
        mkdir $dir
        $"($entry | to json --raw)\n" | save --append ($dir | path join generations.jsonl)
    }
    $gen
}

# Activate this user's standalone home from the commit the switch deployed.
# Returns `{ home: record, step: record | null, ok: bool, output: string }`.
def activate-home [last, verbose: bool]: nothing -> record {
    let name = (home-name)
    if $last == null or ($last.rev? | is-empty) {
        let msg = "The switch recorded no revision, so no home was activated; run home-activate."
        print --stderr (format-step-line error home '' $msg)
        return { home: { status: failed, name: $name, generation: (profile-generation (home-profile)), error: $msg }, step: { step: home, state: error, took: '0sec', detail: $msg }, ok: false, output: '' }
    }
    let short = (short-rev $last.rev)
    if (embedded-home) {
        let gen = (profile-generation (home-profile))
        print --stderr (format-step-line info home '' $"embedded in system(if $gen != null { $" \(gen ($gen))" } else { '' })")
        return { home: { status: embedded, name: $name, generation: $gen }, step: null, ok: true, output: '' }
    }
    let home = (standalone-home $last.rev)
    if $home == null {
        print --stderr (format-step-line info home '' $"none in main at ($short)")
        return { home: { status: none, name: $name, generation: null }, step: null, ok: true, output: '' }
    }
    if (running-home) == $home.path {
        let gen = (profile-generation (home-profile))
        print --stderr (format-step-line info home '' $"already active(if $gen != null { $" \(gen ($gen))" } else { '' })")
        return { home: { status: unchanged, name: $name, generation: $gen }, step: null, ok: true, output: '' }
    }

    let started = (date now)
    print --stderr (format-step-line working home '' $"building ($name) @ ($short)")
    forward { state: working, id: switch/home, app: $APP, msg: $"Activating ($name) from ($short)" }

    let build = if $verbose {
        let out = (try { ^$env.DEPLOY_NIX build --no-link --print-out-paths $home.installable | str trim } catch { '' })
        if ($out | is-empty) { { exit_code: 1, stdout: '', stderr: 'nix build failed' } } else { { exit_code: 0, stdout: $out, stderr: '' } }
    } else {
        ^$env.DEPLOY_NIX build --no-link --print-out-paths $home.installable | complete
    }
    if $build.exit_code != 0 {
        let took = (format-duration ((date now) - $started))
        let err = ($build.stderr | ansi strip | lines | where $it =~ '^error:' | get 0? | default $"nix build exited ($build.exit_code)")
        forward { state: error, id: switch/home, app: $APP, msg: $err }
        print --stderr (format-step-line error home $took $err)
        return {
            home: { status: failed, name: $name, generation: (profile-generation (home-profile)), took: $took, error: $err }
            step: { step: home, state: error, took: $took, detail: $err }
            ok: false
            output: ($build.stderr | lines | last 30 | str join "\n")
        }
    }

    let out = ($build.stdout | str trim)
    print --stderr (format-step-line update home '' 'activating')
    let act = if $verbose {
        let code = (try { ^$"($out)/activate" o>&e; 0 } catch { $env.LAST_EXIT_CODE? | default 1 })
        { exit_code: $code, stdout: '', stderr: '' }
    } else {
        ^$"($out)/activate" | complete
    }
    let took = (format-duration ((date now) - $started))
    if $act.exit_code != 0 {
        let combined = ([$act.stdout $act.stderr] | where { is-not-empty } | str join "\n")
        let err = ($combined | ansi strip | lines | where { str trim | is-not-empty } | last 1 | get 0? | default $"activate exited ($act.exit_code)")
        forward { state: error, id: switch/home, app: $APP, msg: $err }
        print --stderr (format-step-line error home $took $err)
        return {
            home: { status: failed, name: $name, generation: (profile-generation (home-profile)), took: $took, error: $err }
            step: { step: home, state: error, took: $took, detail: $err }
            ok: false
            output: ($combined | lines | last 30 | str join "\n")
        }
    }

    let gen = (record-home $last.rev $out)
    let detail = if $gen != null { $"gen ($gen)" } else { '' }
    forward { state: done, id: switch/home, app: $APP, msg: $"Activated ($name)(if ($detail | is-not-empty) { $' ($detail)' } else { '' })" }
    print --stderr (format-step-line done home $took $detail)
    {
        home: { status: activated, name: $name, generation: $gen, took: $took }
        step: { step: home, state: done, took: $took, detail: $detail }
        ok: true
        output: ''
    }
}

# Each host's ssh destination, from the inventory.
def fleet []: nothing -> record {
    try { $env.DEPLOY_FLEET? | default '{}' | from json } catch { {} }
}

# Run system-switch on another host over ssh. Remote stderr streams straight
# through to local stderr (live progress); remote stdout carries the
# structured summary, plus PST JSON reports when PST_FILE is set locally.
def switch-remote [host: string, destination: string, with_home: bool, json: bool, verbose: bool] {
    print --stderr $"(ansi dark_gray)→ ($host) via ssh \(($destination)\)(ansi reset)"
    let forwarding = ($env.PST_FILE? | is-not-empty)
    # The remote login shell parses this line; `NAME=value command` means
    # the same to Nushell and to POSIX shells.
    let command = (
        (if $forwarding { ['PST_FILE=/dev/stdout'] } else { [] })
        ++ ['system-switch']
        ++ (if $with_home { ['--with-home'] } else { [] })
        ++ (if $json { ['--json'] } else { [] })
        ++ (if $verbose { ['--verbose'] } else { [] })
        | str join ' '
    )
    try {
        ^$"($BIN)/ssh" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 $destination $command
        | lines
        | each {|line|
            let report = if $forwarding and ($line | str starts-with '{') {
                try { $line | from json } catch { null }
            } else { null }
            if ($report | describe | str starts-with 'record') and ($report.app? | is-not-empty) {
                forward $report
            } else {
                print $line
            }
        }
        | ignore
    } catch {|err|
        error make --unspanned { msg: $"system-switch on ($host) failed: ($err.msg). Its revert report, if any, is under ($env.DEPLOY_STATE)/reports/ on ($host)." }
    }
}

def main [
    host?: string  # the host to switch: this one, or another over ssh; defaults to this host
    --with-home    # after a successful switch, activate this user's standalone home from the same commit; a no-op where the system embeds the home
    --json         # print the switch summary as JSON
    --verbose (-v) # stream the raw systemd journal and Home Manager output as they run
] {
    let here = $env.DEPLOY_HOST
    if $host != null and $host != $here {
        let fleet = (fleet)
        let destination = ($fleet | get --optional $host)
        if $destination == null {
            error make --unspanned { msg: $"No host named ($host) in the inventory. Known: ($fleet | columns | str join ', ')." }
        }
        switch-remote $host $destination $with_home $json $verbose
        return
    }

    let gap = (home-gap)
    if $gap != null and not $with_home {
        error make --unspanned { msg: (gap-message $gap) }
    }

    let since = (date now | format date '%Y-%m-%d %H:%M:%S')
    let status_file = ($env.DEPLOY_STATE | path join status.jsonl)
    let previous = (show InvocationID)
    let dir = ($env.HOME | path join .cache system-switch)
    mkdir $dir
    let journal = ($dir | path join $"journal-($nu.pid).log")
    let follower = $"system-switch-journal-($nu.pid)"

    # Follow the journal from before the start, so no line is missed. The
    # follower stops on its own if this process never stops it.
    let followed = (
        ^$"($BIN)/systemd-run" --user --quiet --collect --unit $follower
            --property RuntimeMaxSec=4h
            --property $"StandardOutput=truncate:($journal)"
            $"($BIN)/journalctl" --unit (unit) --since $since --follow --no-pager --output cat
        | complete
    )
    # A run already in progress, such as one the canary timer or an earlier
    # system-switch began, absorbs this start job rather than queueing
    # another, so its invocation never changes. Follow that run as this one.
    let begun = (date now)
    let attached = ($previous | is-not-empty) and ((show ActiveState) in [activating deactivating reloading])
    let started = (^$"($BIN)/systemctl" start --no-block (unit) | complete)
    if $started.exit_code != 0 {
        ^$"($BIN)/systemctl" --user stop $follower | complete | ignore
        error make --unspanned { msg: $"(unit) did not start: ($started.stderr | str trim)" }
    }
    if $attached {
        print --stderr (format-step-line info switch '' $"attached to running (unit)")
    }

    mut seen = { journal: 0, status: 0 }
    mut journal_lines = []
    mut build = { builds: 0, fetches: 0, built: 0, fetched: 0, current: '' }
    mut build_open = true
    mut last_build = { at: ((date now) - 1hr), msg: '' }
    mut tracker = (empty-tracker)
    mut run = if $attached { $previous } else { '' }
    mut finished = false
    while not $finished {
        # A new invocation is this run's; the unit may first wait in its
        # queue or on the lock a manual or automatic switch holds.
        let invocation = (show InvocationID)
        if ($invocation | is-not-empty) and $invocation != $previous { $run = $invocation }
        # A start job that ended without a new invocation never ran the
        # unit, as when a dependency failed. Look again in case it started
        # between the two reads.
        if $run == '' and (show Job | is-empty) {
            let again = (show InvocationID)
            if ($again | is-not-empty) and $again != $previous { $run = $again } else { $finished = true }
        }
        # A run that ends while a start job is still queued, as when the
        # attached run finished just before this start, is followed by
        # that job's own run.
        if $run != '' { $finished = ((show ActiveState) not-in [activating deactivating reloading]) and (show Job | is-empty) }
        # The journal and the status file may trail the unit's end slightly.
        if $finished { sleep 1sec }

        let new = (read-new $journal $seen.journal --final=$finished)
        $seen.journal = $new.offset
        for line in $new.lines {
            $journal_lines = ($journal_lines | append $line)
            if $verbose { print --stderr $line }
            $build = (tally $build $line)
        }

        # Build progress first, so a step's own end always follows it.
        let report = (build-report $build)
        if $build_open and $report.msg != '' and $report.msg != $last_build.msg and ((date now) - $last_build.at) >= 10sec {
            forward $report
            if not $verbose {
                print --stderr (format-step-line update $"build ($report.progress)%" '' $report.msg)
            }
            $last_build = { at: (date now), msg: $report.msg }
        }

        if $run != '' {
            let current = $run
            let read = (read-new $status_file $seen.status --final=$finished)
            $seen.status = $read.offset
            let reports = ($read.lines | each {|line| try { $line | from json } catch { null } } | where {|r| $r != null and $r.run? == $current })
            for report in $reports {
                if $report.id? == 'switch/build' and $report.state? != 'working' { $build_open = false }
                forward ($report | reject --optional run time)
                let step = (record-step $tracker $report $build)
                $tracker = $step.tracker
                if not $verbose and $step.line != null {
                    print --stderr $step.line
                }
            }
        }
        if not $finished { sleep 1sec }
    }
    ^$"($BIN)/systemctl" --user stop $follower | complete | ignore
    rm --force $journal
    if $followed.exit_code != 0 {
        let fallback = (^$"($BIN)/journalctl" --unit (unit) --since $since --no-pager --output cat | complete | get stdout | lines)
        $journal_lines = $fallback
        if $verbose {
            for line in $fallback { print --stderr $line }
        }
    }

    let state = ($env.DEPLOY_STATE | path join last.nuon)
    # A `mut` initialised to null is typed as nothing, so assigning the record
    # later fails; bind it once instead.
    let last = if ($state | path exists) { open $state } else { null }
    let failed_units = (parse-failed-units (^$"($BIN)/systemctl" --failed --no-legend --plain | complete | get stdout))

    let switch_err = if $run == '' {
        # A run that wrote its outcome after this command began was this
        # one, even if its invocation was never seen.
        let at = (try { $last.at | into datetime } catch { null })
        if $at == null or $at < $begun {
            $"(unit) never started; see systemctl status (unit)"
        } else if $last.exit_code? != 0 {
            $"(unit) ended with outcome ($last.outcome? | default unknown)"
        } else { null }
    } else {
        let result = (show Result)
        if $result != 'success' { $"(unit) failed: ($result)" } else { null }
    }

    let home_result = if $switch_err == null and $with_home {
        activate-home $last $verbose
    } else { null }

    let rev = ($last.rev? | default '')
    let subject = if ($tracker.subject | is-not-empty) { $tracker.subject } else { lookup-subject $rev }
    let steps = if $home_result != null and $home_result.step != null {
        $tracker.steps | append $home_result.step
    } else { $tracker.steps }
    let outcome = if $switch_err != null {
        $last.outcome? | default 'failed'
    } else if $home_result != null and not $home_result.ok {
        'home-failed'
    } else {
        $last.outcome? | default 'deployed'
    }

    let summary = (build-summary {
        host: $here
        outcome: $outcome
        rev: $rev
        subject: $subject
        generation: (profile-generation $SYSTEM_PROFILE)
        took: (format-duration ((date now) - $begun))
        steps: $steps
        changes: (parse-closure-diff $journal_lines)
        units: (parse-touched-units $journal_lines)
        home: (if $home_result != null { $home_result.home } else { null })
        failed_units: $failed_units
        report: ($last.report? | default '')
        toplevel: ($last.toplevel? | default '')
        at: ($last.at? | default '')
    })

    if $json {
        print ($summary | to json)
    } else {
        print (format-summary $summary | table --expand --index=false)
    }

    if $switch_err != null {
        if not $verbose and ($steps | where state == 'error' | is-empty) and ($journal_lines | is-not-empty) {
            print --stderr ($journal_lines | last 20 | str join "\n")
        }
        print --stderr $"(ansi red)($switch_err)(ansi reset)"
        exit 1
    }
    if $home_result != null and not $home_result.ok {
        if not $verbose and ($home_result.output | is-not-empty) {
            print --stderr $home_result.output
        }
        exit 1
    }
}
