# Switch this host to a NixOS system in stages. The candidate is activated
# without becoming the boot default, the host's health is watched for a
# window, and only a healthy candidate becomes the default. A breach
# reactivates the previous system, rejects the revision so the canary timer
# leaves it alone, writes a report, and appends a line to the revert log that
# `deploy-reverts` reads. Until the commit, a reboot boots the previous
# system, since the boot default has not moved.
#
# DEPLOY_CONFIG names the JSON settings modules/nixos/system-switch.nix
# writes: the host, the repository, the state directory, the watch window,
# and the host's health probes. The running system's settings judge the
# candidate, so a candidate cannot weaken its own watch.

const DEADMAN = 'nixos-switch-main-deadman'

# The unit's StateDirectory creates the state directory; `apply` run by hand
# may come first.
def settings [] {
    let cfg = (open $env.DEPLOY_CONFIG)
    mkdir $cfg.state
    $cfg
}

def state-file [cfg: record, name: string] { $cfg.state | path join $name }

# Report a step for system-switch to follow: one JSON line in the shape
# osc7501.nu's PST_FILE uses, tagged with this unit run's invocation so the
# follower skips an earlier run's lines. A failed write never stops a switch.
def status [cfg: record, state: string, id: string, msg: string, --progress: int] {
    # nix colours its errors even without a terminal; a report is plain text.
    let text = ($msg | ansi strip | str replace --all --regex '[\x00-\x1f\x7f]' ' ' | lines | where $it != '' | get 0? | default '' | str substring 0..<300)
    let record = { time: (date now | format date '%+'), state: $state, id: $id, app: 'nixos-switch-main', msg: $text, progress: $progress, run: ($env.INVOCATION_ID? | default '') }
    let present = ($record | columns | where {|column| ($record | get $column) != null })
    try { $"($record | select ...$present | to json --raw)\n" | save --append (state-file $cfg status.jsonl) }
}

# Start this run's status file afresh. Probe details and unit names reach
# it, so only wheel, which may read the journal, can read it.
def reset-status [cfg: record] {
    let file = (state-file $cfg status.jsonl)
    try {
        '' | save --force $file
        ^chgrp wheel $file
        ^chmod 0640 $file
    }
}

def active [] { ^readlink --canonicalize /run/current-system | str trim }

def failed-units [] {
    ^systemctl list-units --state=failed --no-legend --plain
    | lines
    | each { str trim | split row ' ' | first }
    | where $it != ''
}

def --wrapped journal [since: datetime, ...args] {
    ^journalctl --no-pager --quiet --output cat $"--since=@($since | format date '%s')" ...$args
    | complete
    | get stdout
    | lines
    | where $it != ''
}

def journal-errors [since: datetime] { journal $since --priority err }

def restart-loops [since: datetime, limit: int] {
    journal $since
    | parse --regex '(?<unit>[\w@.\\-]+\.(?:service|socket|mount)): Scheduled restart job, restart counter is at (?<count>\d+)'
    | update count { into int }
    | sort-by count --reverse
    | uniq-by unit
    | where count >= $limit
}

def run-probe [probe: record] {
    let started = (date now)
    let result = (^timeout $"($probe.timeout)s" $probe.command | complete)
    let seconds = (((date now) - $started) / 1sec | math round --precision 2)
    let output = ([$result.stdout $result.stderr] | str join "\n" | str trim | str substring 0..400)
    let slow = ($probe.latency != null) and ($seconds > $probe.latency)
    let detail = if $result.exit_code == 124 {
        $"timed out after ($probe.timeout)s"
    } else if $result.exit_code != 0 {
        if ($output | is-empty) { $"exited ($result.exit_code)" } else { $"exited ($result.exit_code): ($output)" }
    } else if $slow {
        $"answered in ($seconds)s, over its ($probe.latency)s budget"
    } else {
        $"answered in ($seconds)s"
    }
    { probe: $probe.name, ok: ($result.exit_code == 0 and not $slow), detail: $detail }
}

# One look at the host: units that failed since the baseline, the journal's
# error rate against the baseline's, restart loops, and every named probe.
def sample [cfg: record, baseline: record, since: datetime] {
    let minutes = (((date now) - $since) / 1min)
    let failed = (failed-units | where $it not-in $baseline.failed)
    let errors = (journal-errors $since | length)
    let allowed = ([$cfg.journal.minErrors ($cfg.journal.factor * $baseline.errors_per_minute * $minutes)] | math max | math round)
    let loops = (restart-loops $since $cfg.restarts)
    [
        {
            probe: units
            ok: ($failed | is-empty)
            detail: (if ($failed | is-empty) { "no unit failed" } else { $"newly failed: ($failed | str join ', ')" })
        }
        {
            probe: journal
            ok: ($errors <= $allowed)
            detail: $"($errors) error lines since activation, ($allowed) allowed"
        }
        {
            probe: restarts
            ok: ($loops | is-empty)
            detail: (if ($loops | is-empty) { "no restart loop" } else { $loops | each {|row| $"($row.unit) restarted ($row.count) times" } | str join ', ' })
        }
    ] ++ ($cfg.probes | each {|probe| run-probe $probe })
}

# Sample until the window closes. A check that fails `failures` samples in a
# row breaches the watch, so one slow answer does not revert a switch.
def watch [cfg: record, baseline: record, since: datetime] {
    let deadline = ($since + ($cfg.watch.duration * 1sec))
    mut strikes = {}
    loop {
        let results = (sample $cfg $baseline $since)
        mut breached = []
        for result in $results {
            let count = if $result.ok { 0 } else { ($strikes | get --optional $result.probe | default 0) + 1 }
            $strikes = ($strikes | upsert $result.probe $count)
            if $count >= $cfg.watch.failures {
                $breached = ($breached | append ($result | insert samples $count))
            }
        }
        if ($breached | is-not-empty) { return $breached }
        let failing = ($results | where not ok)
        let elapsed = ([((date now) - $since) ($cfg.watch.duration * 1sec)] | math min)
        let at = $"(($elapsed / 1sec) | math floor)/($cfg.watch.duration)s"
        let progress = (($elapsed / ($cfg.watch.duration * 1sec)) * 100 | math floor)
        let line = if ($failing | is-empty) {
            $"Healthy: all ($results | length) checks pass."
        } else {
            $"Watching: ($failing | each {|row| $'($row.probe): ($row.detail)' } | str join '; ')"
        }
        print $line
        status $cfg working switch/watch $"($at) ($line)" --progress $progress
        if (date now) >= $deadline { return [] }
        sleep ($cfg.watch.interval * 1sec)
    }
}

# Revert a staged switch on its own if the watch never decides, as when its
# process is killed. The transient unit inherits nothing, so it gets the
# settings and PATH explicitly.
def arm-deadman [cfg: record] {
    disarm-deadman
    let after = ($cfg.watch.duration + $cfg.watch.grace)
    let path = (if ($env.PATH | describe) =~ '^list' { $env.PATH | str join (char esep) } else { $env.PATH })
    (^systemd-run --quiet --unit $DEADMAN
        --description "Revert a staged NixOS switch whose watch stopped"
        $"--on-active=($after)s" --timer-property=AccuracySec=1s
        $"--setenv=DEPLOY_CONFIG=($env.DEPLOY_CONFIG)"
        $"--setenv=PATH=($path)"
        $nu.current-exe --no-config-file $env.CURRENT_FILE revert)
}

def disarm-deadman [] {
    ^systemctl stop $"($DEADMAN).timer" | complete | ignore
    ^systemctl reset-failed $"($DEADMAN).timer" $"($DEADMAN).service" | complete | ignore
}

# Who landed the revision and what it says, for the report. The unit only
# needs the commit's metadata, so it fetches main's tip alone.
def describe-rev [cfg: record, rev: string] {
    let fallback = { rev: $rev, release: '', author: unknown, subject: $"main at ($rev | str substring 0..11)", impact: '' }
    let repo = (state-file $cfg source.git)
    try {
        if not ($repo | path exists) { ^git init --quiet --bare $repo }
        ^git -C $repo fetch --quiet --depth 1 $cfg.repo refs/heads/main
        let fields = (^git -C $repo log -1 '--format=%an <%ae>%x1f%s%x1f%(trailers:key=Impact,valueonly,separator=%x2C)' $rev
            | str trim
            | split row (char --integer 31))
        let release = (^git ls-remote --tags $cfg.repo
            | lines
            | parse "{sha}\t{ref}"
            | where sha == $rev
            | get ref
            | each { str replace 'refs/tags/' '' | str replace '^{}' '' }
            | first 1)
        { rev: $rev, release: ($release | get 0? | default ''), author: $fields.0, subject: $fields.1, impact: ($fields.2? | default '') }
    } catch {
        $fallback
    }
}

def fence [rows: list<string>] {
    if ($rows | is-empty) { return "_none_" }
    ["```"] ++ ($rows | each { str substring 0..220 }) ++ ["```"] | str join "\n"
}

# What the breach left behind, gathered before the revert clears it.
def diagnose [pending: record] {
    let since = ($pending.activated? | default $pending.started)
    let failed = (failed-units | where $it not-in $pending.baseline.failed)
    {
        failed: ($failed | first 5 | each {|unit| { unit: $unit, status: (^systemctl status --no-pager --lines 15 $unit | complete | get stdout | str trim) } })
        loops: (restart-loops $since 1)
        # Restart loops repeat one message; keep the latest of each.
        errors: (journal-errors $since | reverse | uniq | reverse | last 40)
    }
}

def render-report [entry: record, breached: list, diagnostics: record] {
    let verb = if $entry.activated { "reverted" } else { "rejected" }
    let release = if ($entry.release | is-empty) { "" } else { $" \(release ($entry.release)\)" }
    [
        $"# ($entry.host) ($verb) ($entry.subject)"
        ""
        $"- Revision `(if ($entry.rev | is-empty) { 'none' } else { $entry.rev })`($release) by ($entry.author)."
        $"- Phase: ($entry.phase). Candidate `(if ($entry.candidate | is-empty) { 'none' } else { $entry.candidate })`."
        (if $entry.activated {
            $"- Reactivated `($entry.previous)`: (if $entry.restored { 'succeeded' } else { '**failed**; the host may be running the candidate' })."
        } else {
            $"- Nothing was activated; the host stays on `($entry.previous)`."
        })
        $"- At ($entry.at)."
        ""
        "## What breached"
        ""
        ($breached | each {|row| $"- `($row.probe)`: ($row.detail | lines | first 1 | get 0? | default '')" } | str join "\n")
        ""
        # A build's or evaluation's error spans many lines.
        ...($breached | where {|row| ($row.detail | lines | length) > 1 } | each {|row| [$"### ($row.probe)" "" (fence ($row.detail | lines | last 60)) ""] | str join "\n" })
        "## Newly failed units"
        ""
        (if ($diagnostics.failed | is-empty) { "_none_" } else { $diagnostics.failed | each {|row| [$"### ($row.unit)" "" (fence ($row.status | lines))] | str join "\n" } | str join "\n\n" })
        ""
        "## Restart loops"
        ""
        (if ($diagnostics.loops | is-empty) { "_none_" } else { $diagnostics.loops | each {|row| $"- `($row.unit)` restarted ($row.count) times" } | str join "\n" })
        ""
        "## Journal errors since activation"
        ""
        (fence $diagnostics.errors)
        ""
        "## Close the gap"
        ""
        "This revision passed every pre-land check, so the watch found what they"
        "missed. Add the check that would have caught it before deployment, a flake"
        "check or an assertion in tests/deploy-revert.nix, and fill in the failure"
        "record in docs/ci-failure-review.md. `deploy-reverts` tallies which checks"
        "cause reverts, so the most frequent gap is the next one to close."
        ""
    ] | str join "\n"
}

# The revert log is the feedback loop's record: one JSON line per staged
# switch that did not become the boot default, with the report beside it.
# Reports quote the journal, so only wheel, which may read the journal, can
# read them.
def record-revert [cfg: record, meta: record, phase: string, breached: list, diagnostics: record, activated: bool, restored: bool] {
    let at = (date now)
    let rev = ($meta.rev? | default '')
    let tag = if ($rev | is-empty) { $meta.candidate? | default '' | path basename | str substring 0..7 } else { $rev | str substring 0..11 }
    let id = $"($at | format date '%Y%m%dT%H%M%S')-($tag)"
    let reports = (state-file $cfg reports)
    mkdir $reports
    ^chgrp wheel $reports
    ^chmod 0750 $reports
    let report = ($reports | path join $"($id).md")
    let entry = {
        id: $id
        at: ($at | format date '%+')
        host: $cfg.host
        phase: $phase
        rev: $rev
        release: ($meta.release? | default '')
        author: ($meta.author? | default unknown)
        subject: ($meta.subject? | default $"store path ($tag)")
        impact: ($meta.impact? | default '')
        candidate: ($meta.candidate? | default '')
        previous: ($meta.previous? | default (active))
        activated: $activated
        restored: $restored
        breached: ($breached | get probe)
        report: $report
    }
    render-report $entry $breached $diagnostics | save --force $report
    ^chmod 0640 $report
    let log = (state-file $cfg reverts.jsonl)
    $"($entry | to json --raw)\n" | save --append $log
    ^chgrp wheel $log
    ^chmod 0640 $log
    if ($rev | is-not-empty) {
        let rejected = (state-file $cfg rejected.nuon)
        let revs = (if ($rejected | path exists) { open $rejected } else { [] })
        $revs | append $rev | uniq | last 50 | to nuon | save --force $rejected
    }
    print $"Wrote ($report)."
    $entry
}

# Record a candidate that never activated, such as one that does not build.
def reject [cfg: record, meta: record, phase: string, detail: string] {
    let none = { failed: [], loops: [], errors: [] }
    record-revert $cfg $meta $phase [{ probe: $phase, ok: false, detail: $detail }] $none false true
}

def revert [cfg: record, pending: record, phase: string, breached: list] {
    disarm-deadman
    let diagnostics = (diagnose $pending)
    print $"Reverting to ($pending.previous)."
    status $cfg working switch/revert $"Reverting to ($pending.previous | path basename)"
    let code = (try { ^$"($pending.previous)/bin/switch-to-configuration" test; 0 } catch { $env.LAST_EXIT_CODE? | default 1 })
    let entry = (record-revert $cfg $pending $phase $breached $diagnostics true ($code == 0))
    rm --force (state-file $cfg pending.nuon)
    if $code == 0 {
        status $cfg done switch/revert $"Reverted to ($pending.previous | path basename)"
    } else {
        status $cfg error switch/revert $"Reactivating ($pending.previous | path basename) exited ($code); the host may be running the candidate"
    }
    $entry
}

# The newest system profile generation that points at a store path.
def profile-generation [toplevel: string] {
    ls --long /nix/var/nix/profiles
    | where type == symlink and target == $toplevel
    | each {|link| $link.name | path basename | parse --regex '^system-(?<n>\d+)-link$' }
    | flatten
    | get --optional n
    | default []
    | each { into int }
    | sort
    | last 1
    | get 0?
}

# Pair a store path with the revision that produced it. The commit stays out
# of the closure, where it would change the system on every landing, so this
# log is how `generation` names the source of the running system. An
# `unchanged` line records a later revision that produced the same system.
def record-generation [cfg: record, meta: record, toplevel: string, outcome: string] {
    let entry = {
        at: (date now | format date '%+')
        host: $cfg.host
        outcome: $outcome
        rev: ($meta.rev? | default '')
        release: ($meta.release? | default '')
        subject: ($meta.subject? | default '')
        toplevel: $toplevel
        generation: (profile-generation $toplevel)
    }
    try { $"($entry | to json --raw)\n" | save --append (state-file $cfg generations.jsonl) }
}

# Make a candidate that passed its watch the boot default. A revert by the
# dead-man timer while this run was stalled wins: the candidate is no
# longer active, so it is not committed.
def commit [cfg: record, pending: record] {
    disarm-deadman
    let file = (state-file $cfg pending.nuon)
    if (active) != $pending.candidate or not ($file | path exists) {
        error make { msg: "The staged switch was reverted while its watch ran; nothing was committed." }
    }
    print $"Healthy for ($cfg.watch.duration)s; making it the boot default."
    status $cfg done switch/watch $"Healthy for ($cfg.watch.duration)s"
    status $cfg working switch/commit "Making it the boot default"
    ^nix-env --profile /nix/var/nix/profiles/system --set $pending.candidate
    ^$"($pending.candidate)/bin/switch-to-configuration" boot
    record-generation $cfg $pending $pending.candidate deployed
    rm --force $file
    status $cfg done switch/commit "Made it the boot default"
}

# Activate, watch, then commit or revert. Returns the revert log entry of a
# revert, or null for a committed switch.
def stage [cfg: record, candidate: string, meta: record] {
    let previous = (active)
    print "Previewing service changes..."
    status $cfg working switch/preview "Previewing service changes"
    let previewed = (try { ^$"($candidate)/bin/switch-to-configuration" dry-activate; true } catch { false })
    if not $previewed {
        status $cfg error switch/preview "switch-to-configuration dry-activate failed"
        return (reject $cfg ($meta | merge { candidate: $candidate, previous: $previous }) preview "switch-to-configuration dry-activate failed")
    }
    status $cfg done switch/preview "Previewed service changes"

    # The journal's error rate over a window as long as the watch, so a host
    # that is always noisy is judged against itself.
    let window = ($cfg.watch.duration * 1sec)
    let baseline = {
        failed: (failed-units)
        errors_per_minute: ((journal-errors ((date now) - $window) | length) / ($window / 1min))
    }
    let pending = ($meta | merge { candidate: $candidate, previous: $previous, baseline: $baseline, started: (date now) })
    let file = (state-file $cfg pending.nuon)
    $pending | to nuon | save --force $file
    arm-deadman $cfg

    print $"Activating ($candidate) without making it the boot default..."
    status $cfg working switch/activate $"Activating ($candidate | path basename) without making it the boot default"
    let code = (try { ^$"($candidate)/bin/switch-to-configuration" test; 0 } catch { $env.LAST_EXIT_CODE? | default 1 })
    let pending = ($pending | insert activated (date now))
    $pending | to nuon | save --force $file
    if $code != 0 {
        status $cfg error switch/activate $"switch-to-configuration test exited ($code)"
        return (revert $cfg $pending activation [{ probe: activation, ok: false, detail: $"switch-to-configuration test exited ($code)" }])
    }
    status $cfg done switch/activate "Activated"

    print $"Watching health for ($cfg.watch.duration)s..."
    status $cfg working switch/watch $"Watching health for ($cfg.watch.duration)s" --progress 0
    let breached = (watch $cfg $baseline $pending.activated)
    if ($breached | is-not-empty) {
        let line = $"Breached: ($breached | each {|row| $'($row.probe): ($row.detail)' } | str join '; ')"
        print $line
        status $cfg error switch/watch $line
        return (revert $cfg $pending watch $breached)
    }
    commit $cfg $pending
    null
}

# Evaluate an attribute of the flake, raising its stderr so a rejection's
# report says why. Without --label, an inherited NIXOS_LABEL is dropped.
def nix-eval [attr: string, --label: string] {
    let result = (if $label == null {
        ^env -u NIXOS_LABEL nix eval --raw --impure $attr | complete
    } else {
        ^env $"NIXOS_LABEL=($label)" nix eval --raw --impure $attr | complete
    })
    if $result.exit_code != 0 {
        error make { msg: ($result.stderr | lines | last 40 | str join "\n") }
    }
    $result.stdout | str trim
}

def save-last [cfg: record, state: record] {
    $state | upsert at (date now | format date '%+') | to nuon | save --force (state-file $cfg last.nuon)
}

# Switch to Tangled's main, giving each distinct closure a stable,
# recognizable boot label. With --auto, as the canary timer runs it, a
# revision already deployed or rejected is left alone until main moves.
def main [
    --auto # skip a revision this host already handled
] {
    let cfg = (settings)
    let rev = (try { ^git ls-remote $cfg.repo refs/heads/main | lines | first | split row "\t" | first | str trim } catch { '' })
    if ($rev | is-empty) {
        error make { msg: $"Could not resolve main on ($cfg.repo)." }
    }
    let last_file = (state-file $cfg last.nuon)
    let last = (if ($last_file | path exists) { open $last_file } else { {} })
    let rejected_file = (state-file $cfg rejected.nuon)
    let rejected = (if ($rejected_file | path exists) { open $rejected_file } else { [] })
    let short = ($rev | str substring 0..11)
    if $auto and ($last.rev? == $rev or $rev in $rejected) {
        return
    }
    reset-status $cfg
    if $rev in $rejected {
        print $"main at ($short) was rejected before; staging it again on request."
    }

    let meta = (describe-rev $cfg $rev)
    let flake = $"git+($cfg.repo)?ref=main&rev=($rev)"
    let system = $"($flake)#nixosConfigurations.($cfg.host).config.system"
    print $"Switching ($cfg.host) to main at ($short): ($meta.subject)"
    status $cfg working switch $"Switching ($cfg.host) to main at ($short): ($meta.subject)"

    status $cfg working switch/evaluate $"Evaluating ($cfg.host)"
    let evaluated = (try {
        let base_path = (nix-eval $"($system).build.toplevel.outPath")
        let base_label = (nix-eval $"($system).nixos.label")
        let fingerprint = ($base_path | path basename | split row "-" | first)
        let label = $"($base_label)-($fingerprint)"
        let candidate = (nix-eval $"($system).build.toplevel.outPath" --label $label)
        { label: $label, candidate: $candidate }
    } catch {|err|
        { error: ($err.msg) }
    })
    if ($evaluated.error? != null) {
        status $cfg error switch/evaluate $"Evaluating ($cfg.host) failed: ($evaluated.error | lines | where $it =~ 'error' | get 0? | default $evaluated.error)"
        let entry = (reject $cfg $meta eval $"Evaluating ($cfg.host) failed: ($evaluated.error)")
        save-last $cfg { rev: $rev, toplevel: '', label: '', outcome: rejected, exit_code: 1, report: $entry.report }
        status $cfg error switch $"Rejected main at ($short): evaluation failed; report ($entry.report)"
        exit 1
    }
    let candidate = $evaluated.candidate
    let state = { rev: $rev, toplevel: $candidate, label: $evaluated.label }
    status $cfg done switch/evaluate $"Evaluated ($evaluated.label)"

    if $candidate == (active) {
        print "That configuration is already active; no generation created."
        record-generation $cfg $meta $candidate unchanged
        save-last $cfg ($state | merge { outcome: active, exit_code: 0 })
        status $cfg done switch "That configuration is already active; no generation created"
        return
    }

    # Build the exact closure gently, then stage that store path. Under the
    # unit, nix writes its progress straight to the journal, where
    # system-switch follows it as it happens, and a rejection reads this
    # run's lines back from there.
    let free = (^df -h --output=avail /nix | lines | last | str trim)
    print "Free space on /nix:"
    ^df -h /nix
    print "Building the closure with one job and two cores..."
    status $cfg working switch/build $"Building the closure with one job and two cores, ($free) free on /nix"
    let nix_build = {|| ^env $"NIXOS_LABEL=($evaluated.label)" nix build --no-link --impure --max-jobs 1 --cores 2 $"($system).build.toplevel" }
    let started = (date now)
    let build = if ($env.INVOCATION_ID? | is-empty) {
        let result = (do $nix_build | complete)
        print $result.stderr
        $result
    } else {
        let code = (try { do $nix_build; 0 } catch { $env.LAST_EXIT_CODE? | default 1 })
        ^journalctl --sync | complete | ignore
        { exit_code: $code, stderr: (journal $started $"_SYSTEMD_INVOCATION_ID=($env.INVOCATION_ID)" | str join "\n") }
    }
    if $build.exit_code != 0 {
        # The first derivation that failed is the cause; the toplevel's own
        # failure only repeats it, and other errors may be warnings.
        let errors = ($build.stderr | ansi strip | lines | where $it =~ '^error:' | str replace --all --regex '/nix/store/[0-9a-z]{32}-' '')
        let cause = ($errors | where $it =~ '^error: Cannot build' | append $errors | get 0? | default $"nix build exited ($build.exit_code)")
        status $cfg error switch/build $cause
        let entry = (reject $cfg ($meta | merge { candidate: $candidate }) build ($build.stderr | lines | last 60 | str join "\n"))
        save-last $cfg ($state | merge { outcome: rejected, exit_code: $build.exit_code, report: $entry.report })
        status $cfg error switch $"Rejected main at ($short): the build failed; report ($entry.report)"
        exit $build.exit_code
    }
    print $"Built ($candidate)."
    status $cfg done switch/build $"Built ($candidate | path basename)"

    let reverted = (stage $cfg $candidate $meta)
    if $reverted == null {
        save-last $cfg ($state | merge { outcome: deployed, exit_code: 0 })
        status $cfg done switch $"Deployed main at ($short) on ($cfg.host)"
    } else {
        save-last $cfg ($state | merge { outcome: reverted, exit_code: 1, report: $reverted.report })
        let verb = if $reverted.activated { 'Reverted' } else { 'Rejected' }
        status $cfg error switch $"($verb) main at ($short) in its ($reverted.phase) phase; report ($reverted.report)"
        exit 1
    }
}

# Stage an already built toplevel, such as a NixOS test's specialisation.
def "main apply" [toplevel: string] {
    let cfg = (settings)
    let candidate = (^readlink --canonicalize $toplevel | str trim)
    if $candidate == (active) {
        print "That configuration is already active."
        return
    }
    let meta = { rev: '', release: '', author: unknown, subject: $"store path ($candidate | path basename)", impact: '' }
    if (stage $cfg $candidate $meta) != null {
        exit 1
    }
}

# Run by the dead-man timer: revert a staged switch that is still pending.
def "main revert" [] {
    let cfg = (settings)
    let file = (state-file $cfg pending.nuon)
    if not ($file | path exists) { return }
    let pending = (open $file)
    if (active) != $pending.candidate {
        rm --force $file
        return
    }
    print "The staged switch stopped before its watch decided; reverting."
    let limit = ($cfg.watch.duration + $cfg.watch.grace)
    revert $cfg $pending deadman [{ probe: watch, ok: false, detail: $"the watch did not decide within ($limit)s" }] | ignore
}
