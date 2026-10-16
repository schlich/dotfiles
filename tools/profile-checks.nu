# Profile how long a flake's checks take to evaluate and how much memory each
# needs, to see what ci's local clearance spends its time on.
#
# `main` evaluates each check's drvPath in its own `nix eval`, with Nix's
# sampling `eval-profiler` writing collapsed stacks and `NIX_SHOW_STATS`
# writing the evaluator's counters, and renders a flamegraph per check. GNU
# time gives wall time, CPU time and peak RSS. Each evaluation runs in a
# transient user unit with the memory limits of ci's local checks unit, so a
# runaway check is stopped there rather than by the desktop's OOM killer, and
# the unit's own memory peak is what those limits apply to.
#
# `workers` evaluates every check the way clearance does, with nix-eval-jobs
# and a fixed number of workers, and measures the unit's memory peak and wall
# time: the direct test of whether more eval workers fit the unit's limits.
# nix-eval-jobs 2.35 treats `--max-memory-size` as a shared budget of
# workers * max-memory-size: past it, it kills the largest worker mid-check
# and retries that check alone, and fails a check that exceeds it alone.
#
# Both write to a new directory under ~/.cache/nix-profile-checks and print
# its path, and both refuse to start beside a running nix-eval-jobs, such as
# a ci landing's clearance, which would skew the time and memory measured.
# Tool paths come from the wrapper's environment.

# ci's local checks unit (ci.nu, `local-checks-state`).
const UNIT_LIMITS = [-p MemoryHigh=7G -p MemoryMax=9G -p MemorySwapMax=2G]
# ci's `--eval-max-memory-size`, in MiB.
const EVAL_MEMORY_MIB = 6144
const TIME_FORMAT = '{"wall_s": %e, "user_s": %U, "sys_s": %S, "max_rss_kib": %M, "exit": %x}'

def tool [name: string, fallback: string] {
    $env | get --optional $name | default $fallback
}

def ensure-quiet [force: bool] {
    let busy = (ps | where name == "nix-eval-jobs" | length)
    if $busy > 0 and not $force {
        error make { msg: $"($busy) nix-eval-jobs processes are running, probably a ci clearance; wait for them or pass --force" }
    }
}

def out-dir [label: string, out?: path] {
    let dir = if $out != null { $out } else {
        let cache = ($env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache))
        $cache | path join nix-profile-checks $"(date now | format date '%Y%m%dT%H%M%S')-($label)"
    }
    mkdir $dir
    $dir | path expand
}

# The flake as a locked store path, so every evaluation reads the same source
# and none copies or hashes it again.
def locked-source [flake: string] {
    let meta = (^nix flake metadata --json $flake | from json)
    let hash = ($meta.locked?.narHash? | default "")
    {
        ref: (if $hash == "" { $"path:($meta.path)" } else { $"path:($meta.path)?narHash=($hash)" })
        path: $meta.path
        original: $flake
        rev: ($meta.revision? | default ($meta.dirtyRevision? | default null))
    }
}

# Run `command` in a transient user unit with ci's memory limits when a user
# manager is reachable, under GNU time either way. Returns time's numbers and
# the unit's memory and swap peaks (null without a unit).
def measured [command: list<string>, timing: path, env_vars: record] {
    let time = (tool PROFILE_CHECKS_TIME time)
    let inner = [$time -o $timing -f $TIME_FORMAT ...$command]
    let unit = ($env.XDG_RUNTIME_DIR? | is-not-empty)
    let result = if $unit {
        let setenv = ($env_vars | items {|k, v| $"--setenv=($k)=($v)" })
        ^systemd-run --user --wait --pipe --collect --same-dir ...$UNIT_LIMITS ...$setenv -- ...$inner | complete
    } else {
        with-env $env_vars { ^$inner.0 ...($inner | skip 1) | complete }
    }
    let timed = (try { open --raw $timing | lines | where $it starts-with '{' | last | from json } catch { {} })
    let summary = ($result.stderr | lines | where $it =~ 'Memory peak:' | last 1 | parse --regex 'Memory peak: (?<peak>\S+) \(swap: (?<swap>\S+)\)')
    let mib = {|size| ($size | str replace --regex '([KMGT])$' '${1}iB' | into filesize) / 1MiB | math round --precision 0 }
    {
        exit_code: ($timed.exit? | default $result.exit_code)
        wall_s: ($timed.wall_s? | default null)
        cpu_s: (if ($timed.user_s? | is-empty) { null } else { $timed.user_s + $timed.sys_s | math round --precision 2 })
        max_rss_mib: (if ($timed.max_rss_kib? | is-empty) { null } else { $timed.max_rss_kib / 1024 | math round --precision 0 })
        unit_peak_mib: (if ($summary | is-empty) { null } else { do $mib $summary.0.peak })
        unit_swap_mib: (if ($summary | is-empty) { null } else { do $mib $summary.0.swap })
        stdout: $result.stdout
        stderr: $result.stderr
    }
}

def check-names [source: string, system: string] {
    ^nix eval --json $"($source)#checks.($system)" --apply builtins.attrNames | from json
}

def to-markdown [rows: list] {
    if ($rows | is-empty) { return "" }
    let columns = ($rows | columns)
    let header = $"| ($columns | str join ' | ') |"
    let rule = $"| ($columns | each { '---' } | str join ' | ') |"
    let body = ($rows | each {|row| $"| ($columns | each {|c| $row | get $c | default '' | into string } | str join ' | ') |" })
    [$header $rule ...$body] | str join "\n"
}

# Rank each check by evaluation time and memory, with a flamegraph per check.
def main [
    flake: string = "path:."   # Flake whose checks to profile
    --system: string = "x86_64-linux"
    --only: string             # Profile only these checks, comma-separated
    --out: path                # Output directory (default: a new one under ~/.cache/nix-profile-checks)
    --frequency: int = 99      # eval-profiler samples per second
    --no-profile               # Skip the eval-profiler (timing and stats only)
    --force                    # Run even beside another nix-eval-jobs
] {
    ensure-quiet $force
    let source = (locked-source $flake)
    let names = if $only != null { $only | split row "," | str trim } else { check-names $source.ref $system }
    let dir = (out-dir "checks" $out)
    let nix = (which nix | get 0.path)
    let flamegraph = (tool PROFILE_CHECKS_FLAMEGRAPH inferno-flamegraph)
    let total = ($names | length)
    print $"Profiling ($total) checks of ($source.original) into ($dir)"
    {
        flake: $source
        system: $system
        nix: (^$nix --version | str trim)
        host: (sys host | get hostname)
        started: (date now | format date '%+')
        profiler: (if $no_profile { null } else { { frequency: $frequency } })
    } | to json | save --force ($dir | path join meta.json)

    let rows = ($names | enumerate | each {|entry|
        let name = $entry.item
        let base = ($dir | path join $name)
        let profile = if $no_profile { [] } else {
            [--option eval-profiler flamegraph --option eval-profile-file $"($base).folded" --option eval-profiler-frequency ($frequency | into string)]
        }
        let command = [$nix eval --raw --no-eval-cache ...$profile $"($source.ref)#checks.($system).\"($name)\".drvPath"]
        let run = (measured $command $"($base).time.json" { NIX_SHOW_STATS: "1", NIX_SHOW_STATS_PATH: $"($base).stats.json" })
        let stats = (try { open $"($base).stats.json" } catch { {} })
        if $run.exit_code != 0 { $run.stderr | save --force $"($base).stderr.log" }
        let svg = if $no_profile or not ($"($base).folded" | path exists) { null } else {
            let rendered = (open --raw $"($base).folded" | ^$flamegraph --title $"($name) evaluation" --countname samples | complete)
            if $rendered.exit_code == 0 { $rendered.stdout | save --force $"($base).svg"; $"($name).svg" } else { null }
        }
        let row = {
            check: $name
            ok: ($run.exit_code == 0)
            wall_s: $run.wall_s
            cpu_s: $run.cpu_s
            max_rss_mib: $run.max_rss_mib
            unit_peak_mib: $run.unit_peak_mib
            unit_swap_mib: $run.unit_swap_mib
            gc_heap_mib: (if ($stats.gc?.heapSize? | is-empty) { null } else { $stats.gc.heapSize / 1048576 | math round --precision 0 })
            allocated_mib: (if ($stats.gc?.totalBytes? | is-empty) { null } else { $stats.gc.totalBytes / 1048576 | math round --precision 0 })
            gc_s: ($stats.time?.gc? | default null)
            thunks: ($stats.nrThunks? | default null)
            function_calls: ($stats.nrFunctionCalls? | default null)
            flamegraph: $svg
        }
        print $"[($entry.index + 1)/($total)] ($name): ($row.wall_s)s wall, ($row.cpu_s)s cpu, ($row.max_rss_mib) MiB rss, unit peak ($row.unit_peak_mib) MiB(if $row.ok { '' } else { ', FAILED' })"
        $row
    } | sort-by --reverse wall_s)

    $rows | to json | save --force ($dir | path join ranking.json)
    let summary = {
        checks: $total
        failed: ($rows | where not ok | length)
        wall_s_total: ($rows | get wall_s | compact | math sum | math round --precision 1)
        max_rss_mib: ($rows | get max_rss_mib | compact | math max)
        max_unit_peak_mib: ($rows | get unit_peak_mib | compact | append 0 | math max)
    }
    $summary | to json | save --force ($dir | path join summary.json)
    let table = ($rows | select check ok wall_s cpu_s max_rss_mib unit_peak_mib gc_heap_mib allocated_mib thunks)
    [
        $"# Check evaluation profile"
        ""
        $"($source.original) \(($source.path)\), ($total) checks, ($summary.wall_s_total) s in total; largest peak RSS ($summary.max_rss_mib) MiB."
        ""
        (to-markdown $table)
        ""
    ] | str join "\n" | save --force ($dir | path join ranking.md)
    print ($table | table --width 120)
    print $"Wrote ($dir)/ranking.md, ranking.json and one .svg flamegraph per check."
}

# Evaluate every check at once with nix-eval-jobs and `workers` workers, the
# way local clearance does, and report the unit's memory peak and wall time.
def "main workers" [
    workers: int               # Number of nix-eval-jobs workers
    flake: string = "path:."   # Flake whose checks to evaluate
    --system: string = "x86_64-linux"
    --max-memory-size: int = $EVAL_MEMORY_MIB  # MiB per worker; the budget is workers times this
    --out: path                # Output directory (default: a new one under ~/.cache/nix-profile-checks)
    --force                    # Run even beside another nix-eval-jobs
] {
    ensure-quiet $force
    let source = (locked-source $flake)
    let dir = (out-dir $"workers-($workers)" $out)
    let jobs = (tool PROFILE_CHECKS_EVAL_JOBS nix-eval-jobs)
    print $"Evaluating ($source.original) checks with ($workers) workers, ($max_memory_size) MiB each, into ($dir)"
    let command = [$jobs --workers ($workers | into string) --max-memory-size ($max_memory_size | into string) --flake $"($source.ref)#checks.($system)"]
    let run = (measured $command ($dir | path join time.json) {})
    let results = ($run.stdout | lines | each {|line| try { $line | from json } catch { null } } | compact)
    $run.stderr | save --force ($dir | path join stderr.log)
    let summary = {
        flake: $source
        workers: $workers
        max_memory_size_mib: $max_memory_size
        exit_code: $run.exit_code
        checks: ($results | length)
        failed: ($results | where {|r| ($r.error? | default null) != null } | get --optional attr)
        wall_s: $run.wall_s
        cpu_s: $run.cpu_s
        largest_process_rss_mib: $run.max_rss_mib
        unit_peak_mib: $run.unit_peak_mib
        unit_swap_mib: $run.unit_swap_mib
    }
    $summary | to json | save --force ($dir | path join summary.json)
    print ($summary | reject flake)
    print $"Wrote ($dir)/summary.json"
}
