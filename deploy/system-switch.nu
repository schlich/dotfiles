# Apply the NixOS configuration on Tangled's main without sudo: start the
# root nixos-switch-main unit, follow its journal and step reports while it
# runs, then show its result. modules/nixos/system-switch.nix wraps this with
# DEPLOY_UNIT and DEPLOY_STATE.
#
# deploy/switch.nu writes a JSON line to `status.jsonl` in the state
# directory for each step, tagged with the unit run's invocation. When
# PST_FILE is set, as a `job-log` job sets it, each of this run's reports,
# and the build's progress counted from nix's own lines, is appended there
# as osc7501.nu's `pst report` would, so a job watcher sees every step as it
# happens rather than the whole journal at the end.
#
# The journal is read through the user manager, which writes it to a file
# under ~/.cache, so this also works inside the Claude desktop app's sandbox.

const BIN = '/run/current-system/sw/bin'
const APP = 'nixos-switch-main'

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

def main [] {
    let since = (date now | format date '%Y-%m-%d %H:%M:%S')
    let status_file = ($env.DEPLOY_STATE | path join status.jsonl)
    let previous = (show InvocationID)
    let dir = ($env.HOME | path join .cache system-switch)
    mkdir $dir
    let journal = ($dir | path join $"journal-($nu.pid).log")
    let follower = $"system-switch-journal-($nu.pid)"
    print $"Switching to main through (unit); a new system becomes the boot default once the units it touched settle and its probes pass..."

    # Follow the journal from before the start, so no line is missed. The
    # follower stops on its own if this process never stops it.
    let followed = (
        ^$"($BIN)/systemd-run" --user --quiet --collect --unit $follower
            --property RuntimeMaxSec=4h
            --property $"StandardOutput=truncate:($journal)"
            $"($BIN)/journalctl" --unit (unit) --since $since --follow --no-pager --output cat
        | complete
    )
    if $followed.exit_code != 0 {
        print $"Could not follow the journal: ($followed.stderr | str trim). Its lines follow at the end."
    }
    let started = (^$"($BIN)/systemctl" start --no-block (unit) | complete)
    if $started.exit_code != 0 {
        ^$"($BIN)/systemctl" --user stop $follower | complete | ignore
        error make { msg: $"(unit) did not start: ($started.stderr | str trim)" }
    }

    mut seen = { journal: 0, status: 0 }
    mut build = { builds: 0, fetches: 0, built: 0, fetched: 0, current: '' }
    mut build_open = true
    mut last_build = { at: ((date now) - 1hr), msg: '' }
    mut run = ''
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
        if $run != '' { $finished = ((show ActiveState) not-in [activating deactivating reloading]) }
        # The journal and the status file may trail the unit's end slightly.
        if $finished { sleep 1sec }

        let new = (read-new $journal $seen.journal --final=$finished)
        $seen.journal = $new.offset
        for line in $new.lines {
            print $line
            $build = (tally $build $line)
        }

        # Build progress first, so a step's own end always follows it.
        let report = (build-report $build)
        if $build_open and $report.msg != '' and $report.msg != $last_build.msg and ((date now) - $last_build.at) >= 10sec {
            forward $report
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
            }
        }
        if not $finished { sleep 1sec }
    }
    ^$"($BIN)/systemctl" --user stop $follower | complete | ignore
    rm --force $journal
    if $followed.exit_code != 0 {
        print (^$"($BIN)/journalctl" --unit (unit) --since $since --no-pager --output cat | complete | get stdout)
    }

    let state = ($env.DEPLOY_STATE | path join last.nuon)
    if ($state | path exists) {
        let last = (open $state)
        print $last
        if ($last.report? | is-not-empty) {
            print $"Revert report: ($last.report)"
        }
    }
    let failed = (^$"($BIN)/systemctl" --failed --no-legend --plain | complete | get stdout | str trim)
    if ($failed | is-not-empty) {
        print $"Failed units:\n($failed)"
    }
    if $run == '' {
        error make { msg: $"(unit) never started; see systemctl status (unit)" }
    }
    let result = (show Result)
    if $result != 'success' {
        error make { msg: $"(unit) failed: ($result)" }
    }
}
