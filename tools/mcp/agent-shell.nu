# Execute a command for an AI agent and return one structured diagnostic record.
#
# The command is evaluated by a clean child Nushell so callers do not depend on
# aliases, functions, prompts, or startup output from the interactive shell.
export def agent-shell [
    command: string
    --max-output: int = 12000
] {
    let limit = if $max_output < 1 { 1 } else { $max_output }
    let result = (
        try {
            do -i {
                ^nu --no-config-file --no-history -c $command
            } | complete
        } catch {|err|
            {
                exit_code: 125
                stdout: ""
                stderr: ($err.msg? | default ($err | to json))
                launch_error: true
            }
        }
    )

    let stdout = ($result.stdout | str trim)
    let stderr = ($result.stderr | str trim)
    let stdout_truncated = ($stdout | str length) > $limit
    let stderr_truncated = ($stderr | str length) > $limit
    let output = if $stdout_truncated {
        $stdout | str substring 0..($limit - 1)
    } else {
        $stdout
    }
    let error = if $stderr_truncated {
        $stderr | str substring 0..($limit - 1)
    } else {
        $stderr
    }
    let ok = $result.exit_code == 0
    let searchable_error = (($stderr + "\n" + $stdout) | str lowercase)
    let kind = if $ok {
        "success"
    } else if ($result.launch_error? | default false) {
        "nushell"
    } else if (($searchable_error | str contains "command not found") or ($searchable_error | str contains "not found") or ($searchable_error | str contains "neither a known external")) {
        "not_found"
    } else if ($searchable_error | str contains "permission denied") {
        "permission"
    } else if ($searchable_error | str contains "nu::") {
        "nushell"
    } else {
        "external"
    }

    {
        schema: "nushell.ai/v1"
        ok: $ok
        kind: $kind
        command: $command
        cwd: $env.PWD
        exit_code: $result.exit_code
        stdout: $output
        stderr: $error
        stdout_truncated: $stdout_truncated
        stderr_truncated: $stderr_truncated
        summary: (if $ok {
            "Command completed successfully"
        } else {
            $"Command failed with exit code ($result.exit_code)"
        })
    }
}
