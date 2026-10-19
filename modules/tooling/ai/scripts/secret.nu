# Use a SecretSpec secret without letting its value reach a pipeline's
# output, where shells and agent tools record it (the Nushell MCP server's
# $history, atuin's captured output).

# Commands for handing secrets to code without printing them.
def secret [] { help secret }

# Run CLOSURE with the value of the SecretSpec secret NAME and return what
# it returns. Refuses a result that contains the value itself.
#
# secret with STITCH_API_KEY --reason 'probe Stitch' {|key| mcp probe http https://stitch.googleapis.com/mcp --headers {X-Goog-Api-Key: $key} }
def "secret with" [
    name: string        # The secret's name in secretspec.toml
    closure: closure    # Called with the value as its only argument
    --reason (-r): string   # Why it is read; SecretSpec requires one from agents (default: $env.SECRETSPEC_REASON)
    --file (-f): path       # secretspec.toml to read (default: the nearest one above the working directory)
    --profile (-p): string  # SecretSpec profile (default: the user's configured one)
    --provider: string      # SecretSpec provider (default: the user's configured one)
]: nothing -> any {
    let flags = (
        [
            (if $reason != null { [--reason $reason] })
            (if $file != null { [--file $file] })
            (if $profile != null { [--profile $profile] })
            (if $provider != null { [--provider $provider] })
        ] | compact | flatten
    )
    let result = (^secretspec get ...$flags $name | complete)
    let value = ($result.stdout | str trim)
    if $result.exit_code != 0 or ($value | is-empty) {
        error make {
            msg: $"($name) is not available from secretspec"
            help: ($result.stderr | str trim)
        }
    }
    let out = (do $closure $value)
    if ($out | to nuon | str contains $value) {
        error make { msg: $"the closure returned the value of ($name); return something derived from it instead" }
    }
    $out
}
