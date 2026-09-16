def inspect-state-dir [] { ($env.PAIR_STATE_DIR? | default ".pair") }
export def pair-inspect [target: string, operation?: string, amount?: int] {
    let path = if ($target | str starts-with "scratch-") { $"(inspect-state-dir)/scratch/($target).nuon" } else if ($target | str starts-with "run-") { $"(inspect-state-dir)/runs/($target).nuon" } else { $"(inspect-state-dir)/units/($target).nu" }
    if not ($path | path exists) { error make {msg: $"pair target not found: ($target)"} }
    if ($path | path parse | get extension) == "nu" { return {target: $target, operation: "source", source: (open $path | str join "")} }
    let value = (open $path)
    match ($operation | default "metadata") {
        "schema" => {target: $target, schema: ($value.value | describe), columns: (try {$value.value | columns} catch {[]})}
        "type" => {target: $target, type: $value.type}
        "first" => {target: $target, value: (try {$value.value | first ($amount | default 5)} catch {$value.value})}
        "columns" => {target: $target, columns: (try {$value.value | columns} catch {[]})}
        "metadata" => ($value | reject code value)
        _ => {target: $target, error: $"unknown inspect operation: ($operation)"}
    }
}
