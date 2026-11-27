# notebook-serve: start marimo on this host for a notebook or a folder of
# them, in the Python environment of the project that holds it. `notebook
# open` (notebook.nu) runs it in a Rex terminal on the host with the files and
# reads the URL marimo prints there. --dry-run shows what it would start:
#
#   notebook-serve --dry-run ~/Research/whiteboard/notebooks
#
# The project is the nearest folder at or above the target, short of $HOME,
# with a pyproject.toml, pixi.toml, or .envrc. The first rule that fits picks
# how marimo starts:
#
#   pyproject.toml         uv run marimo, adding marimo if the project lacks it
#   pixi.toml              pixi run marimo
#   .envrc with marimo     the direnv environment's python3 -m marimo
#   PEP 723 notebooks      this command's marimo with --sandbox
#   otherwise              this command's marimo
#
# An allowed .envrc wraps the uv and pixi rules too, through `direnv exec`, so
# a devenv or flake shell supplies the system libraries their wheels load.

# marimo from nixpkgs, substituted at build time.
const MARIMO = '@marimo@'
const MARKERS = [pyproject.toml pixi.toml .envrc]

# The nearest folder at or above FOLDER, short of $HOME, that holds a project
# marker; FOLDER itself when none does.
def project-root [folder: path]: nothing -> path {
    let home = ($env.HOME | path expand)
    let parts = ($folder | path split)
    let ancestors = (
        0..<($parts | length)
        | each {|i| $parts | first ($i + 1) | path join }
        | reverse
        | where {|dir| $dir != '/' and $dir != $home and not ($home | str starts-with $"($dir)/") }
    )
    $ancestors
    | where {|dir| $MARKERS | any {|marker| $dir | path join $marker | path exists } }
    | get -o 0
    | default $folder
}

# Whether direnv may load ROOT's own .envrc.
def envrc-allowed [root: path]: nothing -> bool {
    let envrc = ($root | path join .envrc)
    if not ($envrc | path exists) or (which direnv | is-empty) {
        return false
    }
    let status = (do { cd $root; ^direnv status --json } | complete)
    if $status.exit_code != 0 {
        return false
    }
    # allowed: 0 is allowed, 1 not yet allowed, 2 denied.
    let found = ($status.stdout | from json | get -o state.foundRC)
    if $found == null {
        return false
    }
    $found.path == $envrc and $found.allowed == 0
}

# Whether a pyproject.toml asks for marimo itself, in its dependencies, an
# extra, or a dependency group.
def declares-marimo [pyproject: path]: nothing -> bool {
    let project = (try { open $pyproject } catch { {} })
    [
        ($project | get -o project.dependencies | default [])
        ($project | get -o project.optional-dependencies | default {} | values | flatten)
        ($project | get -o dependency-groups | default {} | values | flatten)
        ($project | get -o tool.uv.dev-dependencies | default [])
    ]
    | flatten
    | where {|requirement| ($requirement | describe) == string }
    | any {|requirement| $requirement =~ '^\s*marimo\s*($|[\[<>=!~;\s])' }
}

# Whether TARGET, or a notebook directly in it, declares PEP 723 inline
# script metadata.
def wants-sandbox [target: path]: nothing -> bool {
    let files = if ($target | path type) == dir {
        ls $target | where {|entry| $entry.type == file and ($entry.name | str ends-with '.py') } | get name
    } else {
        [$target]
    }
    $files | any {|file| open --raw $file | lines | first 40 | any {|line| $line =~ '^# /// script\s*$' } }
}

# How to start marimo for TARGET in ROOT's environment: a name for the
# environment, the command before marimo's own arguments, and whether marimo
# should sandbox each notebook.
def choose [root: path, target: path]: nothing -> record<environment: string, command: list<string>, sandbox: bool> {
    let direnv = (envrc-allowed $root)
    let wrap = if $direnv { [direnv exec $root] } else { [] }
    let pyproject = ($root | path join pyproject.toml)
    if ($pyproject | path exists) {
        let with = if (declares-marimo $pyproject) { [] } else { [--with marimo] }
        return {environment: 'uv project', command: [...$wrap uv run ...$with marimo], sandbox: false}
    }
    if ($root | path join pixi.toml | path exists) {
        return {environment: 'pixi project', command: [...$wrap pixi run marimo], sandbox: false}
    }
    if $direnv and ((^direnv exec $root python3 -c 'import marimo' | complete).exit_code == 0) {
        return {environment: 'direnv', command: [...$wrap python3 -m marimo], sandbox: false}
    }
    if (wants-sandbox $target) {
        return {environment: 'PEP 723 sandbox', command: [$MARIMO], sandbox: true}
    }
    {environment: 'nix', command: [$MARIMO], sandbox: false}
}

# Start marimo for TARGET: `marimo edit` on the folder, so every notebook in it
# opens in one server, or with --app `marimo run` on TARGET itself. Further
# arguments go to marimo, before TARGET.
def --wrapped main [
    target: string # notebook file or folder, as this host sees it
    --app # serve read-only as an app with `marimo run`
    --dry-run # print what would start, as JSON, instead of starting it
    ...marimo: string # more options for marimo, such as --watch
]: nothing -> any {
    let path = ($target | path expand)
    if not ($path | path exists) {
        error make {msg: $"notebook-serve: no such file or folder on (sys host | get hostname): ($target)"}
    }
    let folder = if ($path | path type) == dir { $path } else { $path | path dirname }
    let root = (project-root $folder)
    let choice = (choose $root $path)
    let chosen = ($marimo | any {|arg| $arg =~ '^--(no-)?sandbox\b' })
    let sandbox = if $chosen { [] } else if $choice.sandbox { [--sandbox] } else { [--no-sandbox] }
    # `marimo run` serves no token unless asked, and has no update check.
    let mode = if $app { [run --headless --token] } else { [edit --headless --skip-update-check] }
    let served = if $app { $path } else { $folder }
    let command = [...$choice.command ...$mode ...$sandbox ...$marimo $served]
    if $dry_run {
        return ({environment: $choice.environment, root: $root, command: $command} | to json)
    }
    print $"notebook-serve: ($choice.environment) in ($root)"
    print $"notebook-serve: ($command | str join ' ')"
    cd $root
    exec ($command | first) ...($command | skip 1)
}
