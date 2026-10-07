# Explain a boot that ended without a clean shutdown: a freeze followed by a
# power cycle, a panic, or lost power. `collect` runs as root early in the
# next boot and writes a Markdown report from the previous boot's journal;
# `notify` runs in the desktop session and offers to open an agent on it.

const REPORTS = '/var/lib/boot-postmortem'

# Lines of the previous boot's journal.
def --wrapped journal [...args] {
    ^journalctl --no-pager --boot=-1 ...$args | complete | get stdout | lines
}

def fence [rows: list<string>] {
    if ($rows | is-empty) { return "_none_" }
    ["```"] ++ ($rows | each { str substring 0..220 }) ++ ["```"] | str join "\n"
}

def "main collect" [] {
    let boots = (^journalctl --list-boots --output json --no-pager | from json)
    let previous = ($boots | where index == -1)
    if ($previous | is-empty) { return }
    let previous = ($previous | first)
    let boot = ($previous.boot_id | str substring 0..7)
    if (glob $"($REPORTS)/*-($boot).md" | is-not-empty) { return }

    # systemd-shutdown logs its final steps and journald logs its own stop on
    # every orderly shutdown; a freeze or power loss leaves neither.
    let clean = (journal --quiet --output cat SYSLOG_IDENTIFIER=systemd-shutdown | is-not-empty) or ((journal --output cat --lines 1) == ["Journal stopped"])
    if $clean { return }

    let started = ($previous.first_entry * 1000 | into datetime | date to-timezone local)
    let ended = ($previous.last_entry * 1000 | into datetime | date to-timezone local)
    # The final half hour holds what led up to the freeze.
    let since = ($ended - 30min | format date '%Y-%m-%d %H:%M:%S')
    let tail = (journal --output short-iso $"--since=($since)")

    let oom = ($tail | where $it =~ 'Out of memory: Killed process|invoked oom-killer|systemd-oomd.*Killed|oom-kill')
    let pressure = ($tail | where $it =~ 'Under memory pressure' | length)
    let kernel = ($tail | where $it =~ '(?i)kernel:.*(panic|BUG:|blocked for more than|hung_task|watchdog|ring .* timeout|GPU reset|thermal|Call Trace|segfault)')
    let launched = ($tail | parse --regex 'Started \[systemd-run\] (?<command>.+)\.$' | get command | uniq)
    let loops = ($tail
        | parse --regex '(?<unit>[\w@.-]+\.service): Scheduled restart job'
        | group-by unit
        | transpose unit restarts
        | update restarts { length }
        | where restarts >= 5
        | sort-by restarts --reverse)
    let peaks = ($tail
        | parse --regex ' (?<unit>[\w@.-]+\.(?:service|scope)): Consumed .*?, (?<peak>[\d.]+[KMGT]) memory peak'
        | update peak {|row| $"($row.peak)iB" | into filesize }
        | sort-by peak --reverse
        | uniq-by unit
        | first 10)
    # Restart loops repeat one message; keep the latest of each.
    let warnings = ($tail
        | where {|line| $line !~ 'Consumed .* CPU time' and $line =~ '(?i)error|fail|warn|kill|timeout' }
        | wrap line
        | insert message {|row| $row.line | str replace --regex '^\S+ \S+ [^:]+: ' '' }
        | reverse
        | uniq-by message
        | reverse
        | get line
        | last 30)

    let cause = if ($oom | is-not-empty) or $pressure > 0 {
        "memory exhaustion: the OOM killer or memory-pressure warnings fired before the end"
    } else if ($kernel | is-not-empty) {
        "a kernel or GPU fault was logged before the end"
    } else {
        "unknown: no memory or kernel warnings; suspect a hard hang, a display-server freeze, or lost power"
    }

    let report = [
        $"# Unclean shutdown on (sys host | get hostname)"
        ""
        $"- Boot `($previous.boot_id)` ran from ($started | format date '%Y-%m-%d %H:%M') to ($ended | format date '%Y-%m-%d %H:%M:%S')."
        $"- **Likely cause:** ($cause)."
        $"- Memory-pressure warnings in the final 30 minutes: ($pressure)."
        ""
        "Read the full journal with `journalctl --boot=-1`; this report covers its final 30 minutes."
        ""
        "## OOM kills"
        ""
        (fence $oom)
        ""
        "## Largest memory peaks of units that stopped"
        ""
        (if ($peaks | is-empty) { "_none_" } else { $peaks | each {|row| $"- `($row.unit)`: ($row.peak)" } | str join "\n" })
        ""
        "## Commands started with systemd-run"
        ""
        (fence $launched)
        ""
        "## Restart loops"
        ""
        (if ($loops | is-empty) { "_none_" } else { $loops | each {|row| $"- `($row.unit)` restarted ($row.restarts) times" } | str join "\n" })
        ""
        "## Kernel trouble"
        ""
        (fence $kernel)
        ""
        "## Last warnings"
        ""
        (fence $warnings)
        ""
    ] | str join "\n"

    let name = $"($ended | format date '%Y-%m-%dT%H%M')-($boot).md"
    $report | save --force ($REPORTS | path join $name)
    $name | save --force ($REPORTS | path join latest)
}

def "main notify" [] {
    let latest = ($REPORTS | path join latest)
    if not ($latest | path exists) { return }
    let name = (open --raw $latest | str trim)
    let report = ($REPORTS | path join $name)
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state)) | path join boot-postmortem
    let seen = ($state_dir | path join seen)
    if ($seen | path exists) and ((open --raw $seen | str trim) == $name) { return }
    mkdir $state_dir
    $name | save --force $seen

    let cause = (open --raw $report | lines | where $it =~ 'Likely cause' | get 0? | default "" | str replace --regex '^.*\*\*Likely cause:\*\* ' '')
    let choice = (^notify-send --app-name "Boot post-mortem" --icon dialog-warning --urgency critical --wait --action "investigate=Investigate with an agent" --action "open=Open report" "The last session ended without a clean shutdown" $cause | complete | get stdout | str trim)
    let dotfiles = ($env.HOME | path join dotfiles)
    match $choice {
        "investigate" => {
            let prompt = $"Read the boot post-mortem at ($report). Explain why the previous session ended without a clean shutdown and propose a fix in this repository. Do not dispatch, land, or activate anything without asking."
            ^niri msg action spawn -- terminal --directory $dotfiles ai $prompt
        }
        "open" => { ^niri msg action spawn -- terminal --directory $dotfiles editor $report }
        _ => {}
    }
}

def main [] {
    print "Usage: boot-postmortem collect | notify"
}
