# Nix build traces for nix-ci.
#
# In CI, `convert` turns the events tools/ci-trace/collect.py stamped into a
# Perfetto trace (trace.json), a summary for later aggregation
# (trace-summary.json), and Markdown for the job's summary page on stdout.
#
# Locally, `report` downloads recent runs' trace artifacts and ranks the
# derivations CI spent the most time building, and `run` merges one run's
# jobs, steps, and Nix traces into a single Perfetto trace.

const REPO = 'schlich/dotfiles'
const WORKFLOW = 'nix-ci.yml'
const ARTIFACTS = 'nix-trace-*'

# Nix's ActivityType values.
const KINDS = {
  '0': other
  '100': copy
  '101': download
  '102': realise
  '103': copy-paths
  '104': builds
  '105': build
  '106': optimise
  '107': verify
  '108': substitute
  '109': query
  '110': post-build-hook
  '111': build-waiting
  '112': fetch-tree
}

# Track groups in the Perfetto trace, as thread id offsets.
const BUILD_TID = 100
const SUBSTITUTE_TID = 1000
const OTHER_TID = 2000

def store-name [path: string]: nothing -> string {
  $path | path basename | str replace --regex '^[0-9a-z]{32}-' '' | str replace --regex '\.drv$' ''
}

def fmt-secs [secs: number]: any -> string {
  let t = ($secs | math round | into int)
  if $t >= 3600 {
    $"($t // 3600)h ($t mod 3600 // 60)m"
  } else if $t >= 60 {
    $"($t // 60)m ($t mod 60)s"
  } else {
    $"($secs | math round --precision 1)s"
  }
}

def us-to-s []: int -> float { $in / 1_000_000 }

# Give each span the lowest lane free at its start, so overlapping spans
# land on separate Perfetto tracks.
def assign-lanes []: list<record> -> list<record> {
  sort-by start
  | reduce --fold {ends: [], out: []} {|span, acc|
    let free = ($acc.ends | enumerate | where item <= $span.start | get --optional 0.index)
    let lane = ($free | default ($acc.ends | length))
    let ends = if $lane < ($acc.ends | length) {
      $acc.ends | update $lane $span.end
    } else {
      $acc.ends | append $span.end
    }
    {ends: $ends, out: ($acc.out | append ($span | insert lane $lane))}
  }
  | get out
}

def x-event [name: string, cat: string, start: int, end: int, tid: int, args: record = {}]: nothing -> record {
  {name: $name, cat: $cat, ph: X, ts: $start, dur: ([($end - $start) 1] | math max), pid: 1, tid: $tid, args: $args}
}

def thread-names [tids: list<int>]: nothing -> list<record> {
  $tids | uniq | each {|tid|
    let label = if $tid >= $OTHER_TID {
      $"other ($tid - $OTHER_TID + 1)"
    } else if $tid >= $SUBSTITUTE_TID {
      $"substitute ($tid - $SUBSTITUTE_TID + 1)"
    } else {
      $"build ($tid - $BUILD_TID + 1)"
    }
    [
      {name: thread_name, ph: M, pid: 1, tid: $tid, args: {name: $label}}
      {name: thread_sort_index, ph: M, pid: 1, tid: $tid, args: {sort_index: $tid}}
    ]
  } | flatten
}

# Parse collect.py's stamped events into spans, microseconds from the first event.
def load-spans [events: path]: nothing -> record {
  let rows = (
    open --raw $events | lines | where $it != '' | each {|line|
      let parts = ($line | split row --number 2 "\t")
      try { $parts.1 | from json | insert ts ($parts.0 | into int) } catch { null }
    } | compact
  )
  if ($rows | is-empty) { return null }
  # collect.py's collector-start row, when present, is the earliest.
  let t0 = ($rows.ts | math min)
  let t_end = ($rows.ts | math max)
  let stops = ($rows | where action == stop | uniq-by id | select id ts | rename id end)
  let phases = (
    $rows | where action == result | each {|r|
      {id: $r.id, start: ($r.ts - $t0), phase: ($r.fields?.0? | default '?')}
    }
  )
  let spans = (
    $rows | where action == start | uniq-by id | join --left $stops id | each {|s|
      let kind = ($KINDS | get --optional ($s.type | into string) | default other)
      let fields = ($s.fields? | default [])
      let on_path = ($kind in [build substitute copy] and ($fields | length) > 0)
      {
        id: $s.id
        parent: ($s.parent? | default 0)
        kind: $kind
        name: (if $on_path { store-name ($fields | first) } else { $s.text? | default '' })
        path: (if $on_path { $fields | first } else { null })
        source: (if $kind == substitute { $fields | get --optional 1 } else { null })
        start: ($s.ts - $t0)
        end: (($s.end? | default $t_end) - $t0)
        unfinished: ($s.end? == null)
      }
    }
  )
  {t0: $t0, window: ($t_end - $t0), spans: $spans, phases: $phases}
}

# Split each build into its phases; a phase lasts until the next one starts.
def with-phases [phases: list<record>]: list<record> -> list<record> {
  each {|b|
    let marks = ($phases | where id == $b.id | sort-by start)
    let spans = if ($marks | is-empty) { [] } else {
      $marks | zip ($marks | skip 1 | get start | append $b.end) | each {|z|
        {phase: $z.0.phase, start: $z.0.start, end: $z.1}
      }
    }
    $b | insert phases $spans
  }
}

def markdown [title: string, summary: record]: nothing -> string {
  let built = $summary.builds
  let subs = $summary.substitutes
  let rows = (
    $built | sort-by dur_s --reverse | first 15 | each {|b|
      let longest = ($b.phases | sort-by dur_s --reverse | get --optional 0)
      let phase = if $longest == null { '' } else { $"($longest.phase) \(($longest.dur_s | fmt-secs $in))" }
      let flag = if $b.unfinished { ' (unfinished)' } else { '' }
      $"| `($b.name)`($flag) | (fmt-secs $b.dur_s) | ($phase) |"
    }
  )
  [
    $"### Nix build trace: ($title)"
    ''
    '| | |'
    '|---|---|'
    $"| Traced window | (fmt-secs $summary.window_s) |"
    $"| Before the first build or substitution | (if $summary.before_first_s == null { 'none ran' } else { fmt-secs $summary.before_first_s }) |"
    $"| Built | ($built | length) derivations, (fmt-secs ($built.dur_s? | default [] | math sum)) summed |"
    $"| Substituted | ($subs | length) paths, (fmt-secs ($subs.dur_s? | default [] | math sum)) summed |"
    $"| Cache lookups | ($summary.queries) |"
    ''
  ] ++ (if ($rows | is-empty) { ['Nothing was built.'] } else {
    ['| Slowest builds | Time | Longest phase |' '|---|---:|---|'] ++ $rows
  }) ++ ['' "Open `trace.json` from this job's `nix-trace-*` artifact at <https://ui.perfetto.dev>." ''] | str join "\n"
}

# Convert collect.py's events into trace.json and trace-summary.json in OUT,
# and print a Markdown summary.
def "main convert" [
  events: path           # events file written by collect.py
  out: path              # directory for trace.json and trace-summary.json
  --title: string = nix  # what was traced, such as checks.home-manager
]: nothing -> string {
  mkdir $out
  let loaded = (load-spans $events)
  if $loaded == null { return $"_No Nix events were traced for ($title)._\n" }

  let builds = ($loaded.spans | where kind == build | with-phases $loaded.phases | assign-lanes)
  let subs = ($loaded.spans | where kind == substitute | assign-lanes)
  # Top-level work that is neither a build nor a substitution, such as
  # fetching flake inputs, when it takes a second or more.
  let others = (
    $loaded.spans
    | where kind in [other fetch-tree] and parent == 0 and ($it.end - $it.start) >= 1_000_000 and name != ''
    | assign-lanes
  )

  let phase_events = (
    $builds | each {|b| $b.phases | insert tid ($BUILD_TID + $b.lane) } | flatten
    | each {|p| x-event $p.phase phase $p.start $p.end $p.tid }
  )
  let events = (
    ($builds | each {|b| x-event $b.name build $b.start $b.end ($BUILD_TID + $b.lane) {path: $b.path, unfinished: $b.unfinished} })
    ++ $phase_events
    ++ ($subs | each {|s| x-event $s.name substitute $s.start $s.end ($SUBSTITUTE_TID + $s.lane) {path: $s.path, from: $s.source} })
    ++ ($others | each {|o| x-event $o.name $o.kind $o.start $o.end ($OTHER_TID + $o.lane) })
  )
  let meta = (
    [{name: process_name, ph: M, pid: 1, args: {name: $title}}]
    ++ (thread-names ($events | get tid))
  )
  {traceEvents: ($meta ++ $events), displayTimeUnit: ms, otherData: {title: $title, t0_us: $loaded.t0}}
  | to json --raw | save --force ($out | path join trace.json)

  let work_starts = (($builds | get start) ++ ($subs | get start))
  let summary = {
    title: $title
    t0_us: $loaded.t0
    window_s: ($loaded.window | us-to-s)
    before_first_s: (if ($work_starts | is-empty) { null } else { $work_starts | math min | us-to-s })
    queries: ($loaded.spans | where kind == query | length)
    builds: (
      $builds | each {|b| {
        name: $b.name
        path: $b.path
        start_s: ($b.start | us-to-s)
        dur_s: ($b.end - $b.start | us-to-s)
        unfinished: $b.unfinished
        phases: ($b.phases | each {|p| {phase: $p.phase, dur_s: ($p.end - $p.start | us-to-s)} })
      } }
    )
    substitutes: (
      $subs | each {|s| {
        name: $s.name
        path: $s.path
        from: $s.source
        start_s: ($s.start | us-to-s)
        dur_s: ($s.end - $s.start | us-to-s)
      } }
    )
  }
  $summary | to json | save --force ($out | path join trace-summary.json)
  markdown $title $summary
}

def gh-json [path: string]: nothing -> any {
  let r = (^gh api $path | complete)
  if $r.exit_code != 0 { error make --unspanned {msg: $"gh api ($path): ($r.stderr | str trim)"} }
  $r.stdout | from json
}

def cache-dir []: nothing -> path {
  $env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join ci-trace
}

# Download the trace artifacts of recent completed runs into the cache.
def fetch-runs [repo: string, runs: int, branch: any]: nothing -> list<record> {
  let filter = if $branch == null { '' } else { $"&branch=($branch | url encode)" }
  let listed = (
    gh-json $"repos/($repo)/actions/workflows/($WORKFLOW)/runs?status=completed&per_page=($runs)($filter)"
    | get workflow_runs
  )
  $listed | each {|run|
    {run: $run.id, branch: $run.head_branch, started: $run.run_started_at, dir: (download-run $repo $run.id)}
  }
}

# Download a completed run's trace artifacts into the cache once.
def download-run [repo: string, run_id: int]: nothing -> path {
  let dir = (cache-dir | path join ($run_id | into string))
  let done = ($dir | path join .done)
  if not ($done | path exists) {
    mkdir $dir
    let r = (^gh run download $run_id --repo $repo --pattern $ARTIFACTS --dir $dir | complete)
    # A run from before tracing, or one whose builds never started, has
    # no trace artifacts; anything else is worth retrying next time.
    if $r.exit_code == 0 or ($r.stderr =~ '(?i)no (valid )?artifacts?') {
      touch $done
    } else {
      print --stderr $"run ($run_id): ($r.stderr | str trim)"
    }
  }
  $dir
}

def load-summaries [fetched: list<record>]: nothing -> list<record> {
  $fetched | each {|f|
    glob ($f.dir | path join '*' 'trace-summary.json') | each {|file|
      open $file | insert run $f.run | insert branch $f.branch | insert dir ($file | path dirname)
    }
  } | flatten
}

# Rank the derivations recent nix-ci runs spent the most time building.
def "main report" [
  --runs: int = 20      # how many recent completed runs to read
  --branch: string      # only runs of this branch, such as luvus/integration
  --repo: string = $REPO
  --checks              # rank checks by traced window instead of derivations
]: nothing -> table {
  let summaries = (load-summaries (fetch-runs $repo $runs $branch))
  if ($summaries | is-empty) {
    error make --unspanned {msg: $"no nix-trace artifacts in the last ($runs) runs"}
  }
  if $checks {
    return (
      $summaries | group-by title --to-table | each {|g| {
        check: $g.title
        runs: ($g.items | length)
        median_s: ($g.items.window_s | math median)
        max_s: ($g.items.window_s | math max)
        built_median: ($g.items | each { $in.builds | length } | math median)
      } }
      | sort-by median_s --reverse
      | update median_s { fmt-secs $in } | update max_s { fmt-secs $in }
      | rename check runs median max
    )
  }
  let builds = (
    $summaries | each {|s|
      $s.builds | reject phases | insert run $s.run | insert check $s.title
    } | flatten
  )
  $builds | group-by name --to-table | each {|g| {
    derivation: $g.name
    runs: ($g.items.run | uniq | length)
    total_min: ($g.items.dur_s | math sum | $in / 60 | math round --precision 1)
    median: ($g.items.dur_s | math median | fmt-secs $in)
    max: ($g.items.dur_s | math max | fmt-secs $in)
    checks: ($g.items.check | uniq | str join ', ')
  } } | sort-by total_min --reverse
}

def to-us []: string -> int { into datetime | into int | $in // 1000 }

# Merge one run's jobs, steps, and Nix build traces into a Perfetto trace.
def "main run" [
  run_id: int
  --repo: string = $REPO
  --out: path            # where to write the trace (default: the cache)
]: nothing -> string {
  let jobs = (
    gh-json $"repos/($repo)/actions/runs/($run_id)/jobs?per_page=100"
    | get jobs | where started_at != null and completed_at != null
  )
  let t0 = ($jobs | each { $in.started_at | to-us } | math min)
  let fetched = (download-run $repo $run_id)
  let traces = (glob ($fetched | path join '*' 'trace.json') | each { open $in })

  let per_job = ($jobs | enumerate | each {|e|
    let job = $e.item
    let pid = $e.index + 1
    let steps = ($job.steps? | default [] | where started_at != null and completed_at != null | each {|s|
      {name: $s.name, cat: step, ph: X, pid: $pid, tid: 0, ts: (($s.started_at | to-us) - $t0), dur: ([((($s.completed_at | to-us) - ($s.started_at | to-us))) 1] | math max), args: {conclusion: $s.conclusion}}
    })
    # The Nix trace whose title names this job's check.
    let check = ($job.name | parse --regex '\((?<check>[^,)]+)' | get --optional 0.check)
    let nix = if $check == null { [] } else {
      $traces | where { $in.otherData.title | str ends-with $".($check)" } | each {|t|
        let shift = $t.otherData.t0_us - $t0
        $t.traceEvents | where ph == X | each { $in | update pid $pid | update ts {|ev| $ev.ts + $shift } }
      } | flatten
    }
    [
      {name: process_name, ph: M, pid: $pid, args: {name: $job.name}}
      {name: thread_name, ph: M, pid: $pid, tid: 0, args: {name: steps}}
      {name: $job.name, cat: job, ph: X, pid: $pid, tid: 0, ts: (($job.started_at | to-us) - $t0), dur: ((($job.completed_at | to-us) - ($job.started_at | to-us))), args: {conclusion: $job.conclusion}}
    ] ++ $steps ++ $nix
  } | flatten)

  let path = ($out | default (cache-dir | path join $"run-($run_id).json"))
  {traceEvents: $per_job, displayTimeUnit: ms} | to json --raw | save --force $path
  $"($path)\nOpen it at https://ui.perfetto.dev"
}

def main []: nothing -> string {
  [
    'ci-trace: Nix build traces from nix-ci'
    ''
    '  ci-trace report [--runs N] [--branch B] [--checks]'
    '      rank derivations (or checks) by the time CI spent on them'
    '  ci-trace run RUN_ID [--out PATH]'
    '      merge one run into a Perfetto trace'
    '  ci-trace convert EVENTS OUT [--title T]'
    '      (CI) turn collect.py events into trace.json and a summary'
  ] | str join "\n"
}
