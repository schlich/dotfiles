# Persistent, explicit state for the pair lifecycle.
def state-dir [] { ($env.PAIR_STATE_DIR? | default ".pair") }
def ensure-state [] {
    let root = (state-dir)
    mkdir $root $"($root)/scratch" $"($root)/runs" $"($root)/artifacts" $"($root)/units"
    if not ($"($root)/session.nuon" | path exists) { {schema: "nushell.pair/v1", results: [], runs: []} | save $"($root)/session.nuon" }
    if not ($"($root)/graph.nuon" | path exists) { {schema: "nushell.pair.graph/v1", units: []} | save $"($root)/graph.nuon" }
}
def read-session [] { ensure-state; open $"(state-dir)/session.nuon" }
def write-session [session: record] { $session | save -f $"(state-dir)/session.nuon" }
def new-id [prefix: string] { $"($prefix)-(date now | format date '%Y%m%d%H%M%S')-(random int 1000..9999)" }

def execute [code: string] {
    let started = (date now)
    let command = $"do { ($code) } | to nuon --indent 2"
    let nu_bin = ($env.PAIR_NU? | default "nu")
    let completed = (try { run-external $nu_bin "--no-config-file" "--no-history" "--error-style" "plain" "-c" $command | complete } catch {|err| {exit_code: 125, stdout: "", stderr: ($err.msg? | default ($err | to nuon))} })
    let finished = (date now)
    let ok = $completed.exit_code == 0
    let value = if $ok { try { $completed.stdout | from nuon } catch { null } } else { null }
    {ok: $ok, value: $value, type: (if $ok { $value | describe } else { "unknown" }), duration: ($finished - $started), diagnostics: (if $ok { [] } else { [$completed.stderr] }), stderr: ($completed.stderr | str trim)}
}

export def pair-eval [code: string] {
    ensure-state
    let id = (new-id "scratch")
    let result = (execute $code | merge {id: $id, status: (if $in.ok { "ok" } else { "error" }), code: $code, created: (date now), kind: "scratch"})
    $result | save -f $"(state-dir)/scratch/($id).nuon"
    let session = (read-session | update results {|s| $s.results | append {id: $id, status: $result.status, kind: "scratch", created: $result.created}})
    write-session $session
    $result | reject code stderr
}

export def pair-add [unit: string, code: string] {
    ensure-state
    let source = if ($code | str contains "def ") { $code } else { $"export def ($unit) [] {\n($code)\n}" }
    let source_path = $"(state-dir)/units/($unit).nu"
    $source | save -f $source_path
    let graph = (open $"(state-dir)/graph.nuon" | upsert units {|g| $g.units | append {id: $unit, source: $source_path, inputs: [], outputs: [], depends_on: [], effects: {reads: [], writes: [], env: [], exec: [], network: false}}})
    $graph | save -f $"(state-dir)/graph.nuon"
    {status: "added", id: $unit, source: $source_path}
}

export def pair-promote [scratch_id: string, unit: string] {
    let path = $"(state-dir)/scratch/($scratch_id).nuon"
    if not ($path | path exists) { error make {msg: $"scratch result not found: ($scratch_id)"} }
    let result = (open $path)
    if $result.status != "ok" { error make {msg: "only successful scratch results can be promoted"} }
    pair-add $unit $result.code
    {status: "promoted", scratch: $scratch_id, unit: $unit}
}

export def pair-run [unit: string] {
    ensure-state
    let source = $"(state-dir)/units/($unit).nu"
    if not ($source | path exists) { error make {msg: $"managed unit not found: ($unit)"} }
    let result = (execute $"source ($source); ($unit)")
    let id = (new-id "run")
    let record = ($result | merge {id: $id, unit: $unit, kind: "run", status: (if $result.ok { "ok" } else { "error" }), created: (date now), inputs: [], dependencies: [], effects: {reads: [], writes: [], env: [], exec: [], network: false}})
    $record | save -f $"(state-dir)/runs/($id).nuon"
    let session = (read-session | update runs {|s| $s.runs | append {id: $id, unit: $unit, status: (if $record.ok { "ok" } else { "error" }), created: $record.created}})
    write-session $session
    $record | reject stderr
}

export def pair-check [] {
    ensure-state
    let units = (open $"(state-dir)/graph.nuon").units
    let nu_bin = ($env.PAIR_NU? | default "nu")
    $units | each {|unit| let check = (try { run-external $nu_bin "--no-config-file" "--no-history" "--error-style" "plain" "--ide-check" "100" $unit.source | complete } catch {|err| {exit_code: 125, stdout: "", stderr: ($err.msg? | default ($err | to nuon))} }); {unit: $unit.id, status: (if $check.exit_code == 0 { "valid" } else { "invalid" }), diagnostics: ($check.stdout | str trim), source: $unit.source}}
}

export def pair-status [] {
    ensure-state
    let session = (read-session)
    let graph = (open $"(state-dir)/graph.nuon")
    {schema: "nushell.pair.status/v1", workspace: (pwd), managed_units: ($graph.units | each {|u| {id: $u.id, source: $u.source, depends_on: $u.depends_on}}), scratch_results: ($session.results | last 10), recent_runs: ($session.runs | last 10), state_dir: (state-dir), integrations: {jj: (".jj" | path exists), checkmate: ("checkmate.toml" | path exists)}}
}
