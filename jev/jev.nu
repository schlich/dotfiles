#!/usr/bin/env -S nu --stdin

# Command-line access to TypeSafe's Jev System One model.
# Questions and thresholds live in the file named by JEV_QUESTIONS.

const endpoint = "https://api.typesafe.ai/v1/systemone"
# Mirrors programs.atuin.settings.history_filter: command lines that assign
# credentials are never sent to the API.
const credential_pattern = '\$env\.[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

# Hook runners spawn jev with a socket for stdin, and Linux cannot reopen a
# socket through /dev/stdin, so read `$in`, which requires `nu --stdin`.
def parse-stdin [input: any] {
    if ($input | describe) == "nothing" {
        error make { msg: "no JSON on stdin; run jev with `nu --stdin`" }
    }
    # `from json` accepts bare words and empty input, so require an object.
    let value = ($input | into string | from json)
    if not ($value | describe | str starts-with "record") {
        error make { msg: $"stdin is not a JSON object \(got ($value | describe)\)" }
    }
    $value
}

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
    let request = (parse-stdin $in)
    let model = ($model | default (questions-config).model)
    ask $request.state $request.questions $model | to json
}

# Decide whether a failed terminal command deserves an agent. Reads a
# `terminal.command.failed` event as JSON on stdin and prints a routing record.
# Any failure to reach Jev routes to triage, preserving the previous behavior.
def "main triage-gate" [] {
    let event = (parse-stdin $in)
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

def bash-guard [input: any] {
    let event = (parse-stdin $input)
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

    let rewrite = ($result.response.answers.nushell_rewrite.noul? | default 0)
    if $rewrite >= $guard.min_nushell_rewrite {
        return {
            hookSpecificOutput: {
                hookEventName: PreToolUse
                permissionDecision: deny
                permissionDecisionReason: $"Jev recommends Nushell \(p=($rewrite)\). Do not run this Bash call. Rewrite it as a Nushell pipeline and run it with the Nushell MCP tool \(mcp__plugin_hm_nushell__evaluate\). For large files, logs, or output, keep the data in a Nushell variable and follow the rlm skill instead of printing it."
            }
        }
    }
    bash-ask $"Jev determined Bash is appropriate \(Nushell rewrite p=($rewrite)\). Confirm before running this command."
}

def "main bash-guard" [] {
    let input = $in
    let output = (try {
        { result: (bash-guard $input) }
    } catch {|err|
        { error: $err.msg }
    })
    if ($output.error? != null) {
        print --stderr $"jev bash-guard: ($output.error)"
        return (bash-ask $"The Jev Bash guard could not inspect this command: ($output.error). Confirm before running it." | to json -r)
    }
    $output.result | to json -r
}

def main [] {
    print "Usage: jev ask | jev triage-gate | jev bash-guard"
}
