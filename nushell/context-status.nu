# Print a JJ workspace's context status when an interactive shell enters it.
#
# The readout appears once per workspace: moving between directories inside
# one workspace stays quiet. Set CONTEXT_STATUS_ON_CD=false to disable it for a
# shell.

# The nearest directory at or above `dir` that holds a JJ workspace.
def context-status-root [dir: path] {
    mut current = ($dir | path expand)
    loop {
        if ($current | path join ".jj" | path type) == "dir" { return $current }
        let parent = ($current | path dirname)
        if $parent == $current { return null }
        $current = $parent
    }
}

export def --env setup-context-status [] {
    let on_pwd_change = {
        condition: {|before, after|
            (
                ($env.CONTEXT_STATUS_ON_CD? | default true | into bool)
                and $nu.is-interactive
                and (is-terminal --stdout)
                and (context-status-root $after) != null
                and (context-status-root $after) != (if $before == null { null } else { context-status-root $before })
            )
        }
        code: {|_, after| ^context-status brief (context-status-root $after) }
    }

    $env.config.hooks.env_change.PWD = (
        $env.config.hooks.env_change.PWD?
        | default []
        | append $on_pwd_change
    )
}
