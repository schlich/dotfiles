#!/usr/bin/env nu

# Command-line access to TypeSafe's Jev System One model.
# Questions and thresholds live in the file named by JEV_QUESTIONS.

const endpoint = "https://api.typesafe.ai/v1/systemone"
# Mirrors programs.atuin.settings.history_filter: command lines that assign
# credentials are never sent to the API.
const credential_pattern = '\$env\.[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

def questions-config [] {
    let path = ($env.JEV_QUESTIONS? | default ($env.FILE_PWD | path join "questions.nuon"))
    open $path
}

# A key with an embedded line break makes the HTTP client fail with an
# opaque "Network failure", so reject it with a clear message instead.
def validated-key [key: string, source: string] {
    let parts = ($key | lines | each { str trim } | where { is-not-empty })
    if ($parts | length) != 1 {
        error make { msg: $"TYPESAFE_API_KEY from ($source) is malformed: expected one line, got ($parts | length) non-empty lines. Store it again as a single line." }
    }
    # Terminal paste shortcuts can leave control characters such as Ctrl-V.
    let invalid = ($parts.0 | split chars | enumerate | where { $in.item !~ '^[\x21-\x7e]$' } | get index)
    if ($invalid | is-not-empty) {
        error make { msg: $"TYPESAFE_API_KEY from ($source) contains non-printable characters at positions ($invalid | str join ', '). Store it again without control characters." }
    }
    $parts.0
}

def api-key [] {
    if ($env.TYPESAFE_API_KEY? | is-not-empty) {
        return (validated-key $env.TYPESAFE_API_KEY "the environment")
    }
    let manifest = ($env.JEV_SECRETSPEC_FILE? | default ($env.FILE_PWD | path join ".." "modules" "secretspec.toml"))
    let result = (^secretspec get --file $manifest --provider keyring --reason "Jev decision request" TYPESAFE_API_KEY | complete)
    if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
        error make { msg: "TYPESAFE_API_KEY is not set and is not available from secretspec." }
    }
    validated-key $result.stdout "secretspec"
}

# Evaluate `state` against typed questions and return the full response.
def ask [state: any, questions: record, model: string] {
    let response = (
        http post $endpoint { state: $state, model: $model, questions: $questions }
            --content-type application/json
            --headers { Authorization: $"Bearer (api-key)" }
            --max-time 15sec
            --full
            --allow-errors
    )
    if $response.status != 200 {
        error make { msg: $"Jev request failed with HTTP ($response.status): ($response.body | to json -r)" }
    }
    $response.body
}

# Ask ad hoc questions. Reads `{state, questions}` JSON from stdin and prints
# the response JSON.
def "main ask" [
    --model: string # Model ID; defaults to the pinned model in the questions file
] {
    let request = (open --raw /dev/stdin | from json)
    let model = ($model | default (questions-config).model)
    ask $request.state $request.questions $model | to json
}

# Decide whether a failed terminal command deserves an agent. Reads a
# `terminal.command.failed` event as JSON on stdin and prints a routing record.
# Any failure to reach Jev routes to triage, preserving the previous behavior.
def "main triage-gate" [] {
    let event = (open --raw /dev/stdin | from json)
    let command = ($event.command? | default "")
    let exit_code = ($event.exit_code? | default null)

    if $command =~ $credential_pattern {
        return ({ route: "triage", reason: "credential assignment is not sent to Jev" } | to json -r)
    }

    let config = (questions-config)
    let gate = $config.triage_gate
    # Send only the command line; captured output stays local.
    let state = {
        command: $command
        cwd: ($event.cwd? | default "" | str replace $env.HOME "~")
        exit_code: $exit_code
    }
    let response = (try {
        { ok: (ask $state $gate.questions $config.model) }
    } catch {|err|
        { error: $err.msg }
    })
    if ($response.error? != null) {
        return ({ route: "triage", reason: $"Jev unavailable: ($response.error)" } | to json -r)
    }
    let response = $response.ok

    let class = $response.answers.failure_class
    let needs_diagnosis = $response.answers.needs_diagnosis.noul
    let skip = (
        ($class.choice in $gate.skip_classes)
        and $class.confidence >= $gate.min_skip_confidence
        and $needs_diagnosis <= $gate.max_skip_needs_diagnosis
    )
    {
        route: (if $skip { "skip" } else { "triage" })
        class: $class.choice
        confidence: $class.confidence
        needs_diagnosis: $needs_diagnosis
        model: $response.model
    } | to json -r
}

# Classify Claude Code Bash tool calls before execution. Reads a PreToolUse
# event from stdin and emits a Claude Code hook decision as JSON. Any Jev
# failure is converted into an explicit user confirmation request.
def bash-ask [reason: string] {
    {
        hookSpecificOutput: {
            hookEventName: PreToolUse
            permissionDecision: ask
            permissionDecisionReason: $reason
        }
    }
}

def shell-quote [value: string] {
    # Bash single-quote escaping. The translated source remains one `nu -c`
    # argument even when it contains spaces, quotes, or shell metacharacters.
    let escaped = ($value | str replace --all "'" "'\\''")
    "'" + $escaped + "'"
}

def bash-guard [] {
    let event = (open --raw /dev/stdin | from json)
    if ($event.tool_name? | default "") != "Bash" {
        return {}
    }
    let tool_input = ($event.tool_input? | default {})
    let command = ($tool_input.command? | default "")
    if ($command | str trim | is-empty) {
        return (bash-ask "The Bash command could not be inspected. Confirm before running it.")
    }
    if $command =~ $credential_pattern {
        return (bash-ask "This Bash command appears to assign a credential. Jev was not sent the command; confirm before running it.")
    }

    let config = (questions-config)
    let guard = $config.bash_guard
    let state = {
        bash_command: $command
        cwd: ($event.cwd? | default "" | str replace $env.HOME "~")
    }
    let result = (try {
        { response: (ask $state $guard.questions $config.model) }
    } catch {|err|
        { error: $err.msg }
    })
    if ($result.error? != null) {
        return (bash-ask $"Jev could not classify this Bash call: ($result.error). Confirm before running it.")
    }

    let answers = $result.response.answers
    let action = ($answers.action.choice? | default "" | str lowercase | str replace --all "-" "_")
    let reason = ($answers.reason.text? | default "" | str trim)
    if $action == "retry_nushell" {
        let message = "Jev recommends Nushell. Do not run this Bash call. Rewrite it using Nushell syntax and try again."
        return {
            hookSpecificOutput: {
                hookEventName: PreToolUse
                permissionDecision: deny
                permissionDecisionReason: (if ($reason | is-empty) { $message } else { $"($message) Reason: ($reason)" })
            }
        }
    }
    if $action == "translate_to_nushell" {
        let source = ($answers.nushell_command.text? | default "" | str trim)
        if ($source | is-empty) {
            return (bash-ask "Jev selected Nushell translation but returned no command. Confirm the original Bash call.")
        }
        let nu_bin = ($env.JEV_NUSHELL? | default "nu")
        let updated = ($tool_input | upsert command $"($nu_bin) -c (shell-quote $source)")
        return {
            hookSpecificOutput: {
                hookEventName: PreToolUse
                permissionDecision: allow
                permissionDecisionReason: (if ($reason | is-empty) { "Translated this command to Nushell." } else { $"Translated to Nushell: ($reason)" })
                updatedInput: $updated
            }
        }
    }
    if $action == "ask_bash" {
        return (bash-ask (if ($reason | is-empty) { "Jev determined Bash is appropriate. Confirm before running this command." } else { $reason }))
    }
    bash-ask $"Jev returned an unrecognized action '($action)'. Confirm before running Bash."
}

def "main bash-guard" [] {
    let output = (try {
        { result: (bash-guard) }
    } catch {|err|
        { error: $err.msg }
    })
    if ($output.error? != null) {
        return (bash-ask $"The Jev Bash guard could not inspect this command: ($output.error). Confirm before running it." | to json -r)
    }
    $output.result | to json -r
}

def main [] {
    print "Usage: jev ask | jev triage-gate | jev bash-guard"
}
