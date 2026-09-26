# Yazelix shell integration.
#
# Yazelix bundles Yazi as `yzx-yazi`, which runs the pinned Yazi with the
# merged Yazelix config inside or outside a session. `yazi` and `y` use it so
# there is a single Yazi install.
#
# Enter a per-project Yazelix session when an interactive shell changes into a
# directory that carries a direnv .envrc. Each project gets one named session,
# so returning to the project reattaches to its tabs and panes.
#
# Set YAZELIX_PROJECT_SESSIONS=false to disable the hook for a shell.

alias yazi = yzx-yazi

# Browse with Yazi and change to the directory it was quit in.
export def --env y [...args] {
    let cwd_file = (mktemp --tmpdir "yazi-cwd.XXXXXX")
    ^yzx-yazi --cwd-file $cwd_file ...$args
    let cwd = (open --raw $cwd_file | str trim)
    rm --force $cwd_file
    if ($cwd | is-not-empty) and $cwd != $env.PWD {
        cd $cwd
    }
}

# Stable, readable session name: project basename plus a short path hash so
# two checkouts with the same basename never share a session.
export def yazelix-project-session-name [dir: path] {
    let base = ($dir | path basename | str lowercase | str replace --all --regex '[^a-z0-9_-]+' '-')
    let digest = ($dir | hash sha256 | str substring 0..5)
    $"($base)-($digest)"
}

# Attach to the project's live session, or create it from the project root.
export def yazelix-project [dir?: path] {
    let root = ($dir | default $env.PWD | path expand)
    let name = (yazelix-project-session-name $root)
    let sessions = (
        ^yzx-zellij list-sessions --no-formatting
        | complete
        | get stdout
        | lines
        | where {|line| $line | str starts-with $"($name) " }
    )

    if ($sessions | any {|line| not ($line | str contains "EXITED") }) {
        ^yzx enter attach $name
        return
    }

    # A resurrectable session would collide with named creation.
    if ($sessions | is-not-empty) {
        ^yzx-zellij delete-session $name | complete | ignore
    }

    cd $root
    ^yzx enter --session $name
}

export def --env setup-yazelix-projects [] {
    let on_pwd_change = {
        condition: {|_, after|
            (
                ($env.YAZELIX_PROJECT_SESSIONS? | default true | into bool)
                and $nu.is-interactive
                and ($env.ZELLIJ? == null)
                and ($env.YAZELIX_STATE_DIR? == null)
                and (is-terminal --stdin)
                and (is-terminal --stdout)
                and ($after | path join ".envrc" | path exists)
            )
        }
        code: {|_, after| yazelix-project $after }
    }

    $env.config.hooks.env_change.PWD = (
        $env.config.hooks.env_change.PWD?
        | default []
        | append $on_pwd_change
    )
}
