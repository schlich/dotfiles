# Publish Nushell command lifecycle events to the local cross.stream store.
# Atuin remains the canonical command journal; XS stores workflow events and
# uses ATUIN_HISTORY_ID as the stable correlation key.

def xs-store [] {
    $env.XS_ADDR? | default ($nu.home-dir | path join ".local" "share" "cross.stream" "store")
}

export def publish-terminal-event [topic: string, event: record] {
    let result = (
        do -i {
            ^xs append (xs-store) $topic --meta ($event | to json -r)
        } | complete
    )

    if $result.exit_code != 0 {
        if not ($env.XS_EVENT_WARNING_SHOWN? | default false) {
            print --stderr "cross.stream is unavailable; terminal events will not be recorded."
            load-env { XS_EVENT_WARNING_SHOWN: true }
        }
    }
}

export def --env setup-terminal-events [] {
    let pre_execution = {||
        let command = (commandline)
        if ($command | is-empty) {
            return
        }

        let event = {
            event_version: 1
            session_id: ($env.ATUIN_SESSION? | default $"nu-($nu.pid)")
            atuin_history_id: ($env.ATUIN_HISTORY_ID? | default null)
            command: $command
            cwd: $env.PWD
            terminal: (if ($env.GHOSTTY_RESOURCES_DIR? != null) {
                "ghostty"
            } else {
                $env.TERM_PROGRAM? | default "unknown"
            })
            started_at: (date now)
        }

        load-env { XS_ACTIVE_COMMAND: ($event | to json -r) }
        publish-terminal-event "terminal.command.started" $event
    }

    let pre_prompt = {||
        let active_json = ($env.XS_ACTIVE_COMMAND? | default null)
        if $active_json == null {
            return
        }

        let active = ($active_json | from json)
        let exit_code = ($env.LAST_EXIT_CODE? | default 0)
        let completed = ($active | merge {
            completed_at: (date now)
            exit_code: $exit_code
            status: (if $exit_code == 0 { "completed" } else { "failed" })
        })

        publish-terminal-event "terminal.command.completed" $completed
        if $exit_code != 0 {
            publish-terminal-event "terminal.command.failed" $completed
        }

        hide-env XS_ACTIVE_COMMAND
    }

    $env.config.hooks.pre_execution = (
        $env.config.hooks.pre_execution
        | default []
        | append $pre_execution
    )
    $env.config.hooks.pre_prompt = (
        $env.config.hooks.pre_prompt
        | default []
        | append $pre_prompt
    )
}
