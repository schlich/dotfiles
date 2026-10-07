# `ci` chooses which jj/ci.nu to run each time it starts, so no copy of the
# workflow goes stale. The installed package, the dev shell, and the MCP server
# all start here; only this launcher is frozen at build time.
#
# A topic that edits jj/ci.nu runs its own copy, so a change to the workflow is
# exercised before it lands. Any other workspace in this repository runs
# main@tangled's copy, which an older workspace may not have checked out yet.
# Outside the repository, `ci` runs the copy bundled with the package.

const TRUNK = "main@tangled"
const SCRIPT = "jj/ci.nu"

# Which copy to run, from what the workspace shows: `bundled`, `topic`, or
# `trunk`. A workspace whose trunk copy cannot be read (no fetch yet, or a
# stale working copy that `ci` itself reports) runs its own.
def launch-choice [facts: record] {
    if not $facts.has_script { return "bundled" }
    if $facts.topic_edits { return "topic" }
    if not $facts.trunk_readable { return "topic" }
    "trunk"
}

# The trunk copy, stored under its hash so concurrent launches agree on a path
# and never read a half-written file.
def cached-trunk-script [source: string] {
    let cache = ($env.XDG_CACHE_HOME? | default ($env.HOME | path join ".cache") | path join "ci")
    mkdir $cache
    let script = ($cache | path join $"ci-($source | hash sha256).nu")
    if not ($script | path exists) {
        let partial = $"($script).(random uuid)"
        $source | save $partial
        mv --force $partial $script
    }
    $script
}

def --wrapped main [...args] {
    let bundled = $env.CI_BUNDLED_SCRIPT
    let root = (^jj root | complete)
    let local = if $root.exit_code == 0 { $root.stdout | str trim | path join $SCRIPT } else { "" }
    let has_script = ($local | is-not-empty) and ($local | path exists)
    let edits = if $has_script {
        ^jj log --no-graph -r $"($TRUNK)..@ & files\(root:\"($SCRIPT)\")" -T 'change_id ++ "\n"' | complete
    } else { { exit_code: 1 stdout: "" } }
    let trunk = if $has_script and $edits.exit_code == 0 {
        ^jj file show -r $TRUNK $"root:\"($SCRIPT)\"" | complete
    } else { { exit_code: 1 stdout: "" } }
    let choice = (launch-choice {
        has_script: $has_script
        topic_edits: ($edits.exit_code == 0 and ($edits.stdout | str trim | is-not-empty))
        trunk_readable: ($trunk.exit_code == 0)
    })
    let script = match $choice {
        "bundled" => $bundled
        "topic" => $local
        "trunk" => (cached-trunk-script $trunk.stdout)
    }
    if $choice == "topic" and $trunk.exit_code == 0 {
        print --stderr $"ci: running this topic's ($SCRIPT), not ($TRUNK)'s."
    }
    # This nu has already parsed NU_LIB_DIRS into a list, which `exec` does
    # not pass on as the script's module path, so hand it over explicitly.
    let lib_dirs = ($env.NU_LIB_DIRS? | default [] | each {|dirs| $dirs | split row (char esep) } | flatten | where {|dir| $dir | is-not-empty })
    let include = if ($lib_dirs | is-empty) { [] } else { ["--include-path" ($lib_dirs | str join (char record_sep))] }
    exec $nu.current-exe --no-config-file ...$include $script ...$args
}
