def state-path [session_id: string] {
    if $session_id !~ '^[a-zA-Z0-9_-]+$' {
        error make { msg: "Invalid Codex session ID." }
    }
    let state_dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    $state_dir | path join "codex-jj-sessions" $"($session_id).json"
}

def block [reason: string] {
    { decision: "block", reason: $reason } | to json
}

def checked [repository: string, ...args: string] {
    let result = (^jj --repository $repository ...$args | complete)
    if $result.exit_code != 0 {
        error make { msg: ($result.stderr | str trim) }
    }
    $result.stdout | str trim
}

def prepare [cwd: string, session_id: string, path: path] {
    let root_result = (^jj --repository $cwd root | complete)
    if $root_result.exit_code != 0 { return }
    let root = ($root_result.stdout | str trim)
    let owner_path = ($root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) {
        let owner = (open $owner_path)
        if not ($owner.finished? | default false) and $owner.session_id != $session_id {
            error make { msg: $"This workspace belongs to Codex task ($owner.session_id), change ($owner.change_id). Use a separate JJ workspace for a different topic." }
        }
    }
    if ($path | path exists) {
        let previous = (open $path)
        if $previous.cwd != $root {
            error make { msg: "This task moved to another workspace. Resolve the recorded session mapping before editing." }
        }
        if not ($owner_path | path exists) {
            if (checked $root log -r @ --no-graph -T change_id) != $previous.change_id {
                error make { msg: "The existing task's change is not checked out. Restore its workspace before migrating session ownership." }
            }
            let claim = ($root | path join ".jj" "codex-session-claim")
            let claimed = (^mkdir $claim | complete)
            if $claimed.exit_code != 0 {
                error make { msg: "Workspace already claimed; inspect its session ownership before continuing." }
            }
            $previous | upsert session_id $session_id | upsert finished false | to json | save --force $owner_path
        }
        return
    }

    # A permanent claim prevents simultaneous startups from both changing @.
    # Finish removes it only after verified delivery. A failed creation removes it.
    let claim = ($root | path join ".jj" "codex-session-claim")
    let claimed = (^mkdir $claim | complete)
    if $claimed.exit_code != 0 {
        error make { msg: "This workspace already has a session claim. Inspect .jj/codex-session.json before recovering it; never steal another task's working copy." }
    }
    try {
        # Independent topics start from trunk, preserving any earlier local work.
        checked $root new main@origin -m "Codex session" | ignore
        let change_id = (checked $root log -r @ --no-graph -T change_id)
        let state = { cwd: $root, session_id: $session_id, change_id: $change_id, described: false, finished: false }
        mkdir ($path | path dirname)
        $state | to json | save --force $owner_path
        $state | to json | save --force $path
    } catch {|err|
        rm --recursive $claim
        error make { msg: $err.msg }
    }
}

def main [event: string] {
    if ($env.CODEX_JJ_SESSION_HOOK? | default "") == "1" { return }
    let hook = (open --raw /dev/stdin | from json)
    let cwd = $hook.cwd? | default ""
    let session_id = $hook.session_id? | default ""
    if ($cwd | is-empty) or ($session_id | is-empty) { return }
    let path = (state-path $session_id)

    try {
        prepare $cwd $session_id $path
        if not ($path | path exists) { return }
        let state = (open $path)
        let owner_path = ($state.cwd | path join ".jj" "codex-session.json")
        if ($owner_path | path exists) and ((open $owner_path).finished? | default false) {
            # Completion permits the archive tool, but no new topic edits here.
            if $event == "guard" and (($hook.tool_name? | default "") =~ "(^Bash$|exec_command$|apply_patch$|^Edit$|^Write$)") {
                block "This topic is finished. Archive this task and start a new task for further work."
            } else {
                { hookSpecificOutput: {
                    hookEventName: ($hook.hook_event_name? | default "UserPromptSubmit")
                    additionalContext: "This JJ topic is finished. Archive this task; use a new task for further code edits."
                } } | to json
            }
            return
        }
        let actual = (checked $state.cwd log -r @ --no-graph -T change_id)
        if $actual != $state.change_id {
            block $"Task owns change ($state.change_id), but this workspace is on ($actual). Restore the correct dedicated workspace before continuing; do not edit another task's change."
            return
        }
        if $event == "first-prompt" and not ($state.described? | default false) {
            let described = (with-env { CODEX_JJ_SESSION_HOOK: "1" } {
                cd $state.cwd
                ^jj-describe $state.change_id --prompt ($hook.prompt? | default "") | complete
            })
            if $described.exit_code != 0 {
                block $"Could not name this JJ change: ($described.stderr | str trim)"
                return
            }
            $state | upsert described true | to json | save --force $path
        }
        if $event == "session-start" {
            { hookSpecificOutput: {
                hookEventName: "SessionStart"
                additionalContext: $"This task owns JJ change ($state.change_id) in ($state.cwd). Keep one topic and rewrite this change throughout the task. Publish in place. Finish and verify delivery before archiving."
            } } | to json
        }
    } catch {|err|
        block $err.msg
    }
}
