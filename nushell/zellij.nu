# Zellij project sessions.
#
# Enter a per-project Zellij session when an interactive shell changes into a
# directory that carries a direnv .envrc. Each project gets one named session,
# so returning to the project reattaches to its tabs and panes, and an exited
# session is resurrected with its layout.
#
# Set ZELLIJ_PROJECT_SESSIONS=false to disable the hook for a shell.

# Stable, readable session name: project basename plus a short path hash so
# two checkouts with the same basename never share a session.
export def zellij-project-session-name [dir: path] {
    let base = ($dir | path basename | str lowercase | str replace --all --regex '[^a-z0-9_-]+' '-')
    let digest = ($dir | hash sha256 | str substring 0..5)
    $"($base)-($digest)"
}

# Attach to the project's session, creating it from the project root.
export def zellij-project [dir?: path] {
    let root = ($dir | default $env.PWD | path expand)
    cd $root
    ^zellij attach --create --force-run-commands (zellij-project-session-name $root)
}

export def --env setup-zellij-projects [] {
    let on_pwd_change = {
        condition: {|_, after|
            (
                ($env.ZELLIJ_PROJECT_SESSIONS? | default true | into bool)
                and $nu.is-interactive
                and ($env.ZELLIJ? == null)
                and (is-terminal --stdin)
                and (is-terminal --stdout)
                and ($after | path join ".envrc" | path exists)
            )
        }
        code: {|_, after| zellij-project $after }
    }

    $env.config.hooks.env_change.PWD = (
        $env.config.hooks.env_change.PWD?
        | default []
        | append $on_pwd_change
    )
}
