def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

def main [endpoint: string] {
    let manifest = "/home/schlich/dotfiles/modules/secretspec.toml"
    let secret = (run-command "reading webhook secret from secretspec" {
        ^secretspec get --file $manifest --provider keyring --reason "register GitHub workflow webhook" JJ_CI_WEBHOOK_SECRET
    })
    if ($secret | is-empty) {
        error make { msg: "SecretSpec returned an empty webhook secret." }
    }

    let repository = (run-command "reading repository metadata" {
        ^gh repo view --json nameWithOwner --jq .nameWithOwner
    })
    let base = ($endpoint | str trim | str trim --char '/')
    let url = $"($base)/github/webhook"
    let hooks = (run-command "listing repository webhooks" {
        ^gh api $"repos/($repository)/hooks"
    } | from json)
    let existing = ($hooks | where config.url == $url | first)
    let body = {
        active: true
        events: ["workflow_run"]
        config: {
            url: $url
            content_type: "json"
            insecure_ssl: "0"
            secret: $secret
        }
    } | to json --raw

    if $existing == null {
        run-command "creating the GitHub webhook" {
            $body | ^gh api --method POST $"repos/($repository)/hooks" --input -
        } | ignore
        print $"Created workflow validation webhook: ($url)"
    } else {
        let hook_id = $existing.id
        run-command "updating the GitHub webhook" {
            $body | ^gh api --method PATCH $"repos/($repository)/hooks/($hook_id)" --input -
        } | ignore
        print $"Updated workflow validation webhook: ($url)"
    }
}
