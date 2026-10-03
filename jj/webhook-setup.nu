const MANIFEST = "/home/schlich/dotfiles/modules/secretspec.toml"
const WEBHOOK_PATH = "/github/webhook"
const NOTIFY_APP = "jj-ci-webhook"

def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

def read-quiet [label: string, command: closure] {
    let result = (do $command | complete)
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

# The public Funnel endpoint for this machine, or null when Tailscale is
# unavailable or logged out.
def tailnet-endpoint [] {
    let result = (do { ^tailscale status --json } | complete)
    if $result.exit_code != 0 { return null }
    let status = ($result.stdout | from json)
    let dns_name = ($status.Self?.DNSName? | default "" | str trim --right --char '.')
    if ($status.BackendState? != "Running") or ($dns_name | is-empty) { return null }
    $"https://($dns_name)"
}

def resolve-repository [repository?: string] {
    if $repository != null { return $repository }
    run-command "reading repository metadata" {
        ^gh repo view --json nameWithOwner --jq .nameWithOwner
    }
}

def find-hook [repository: string, url: string] {
    let hooks = (read-quiet "listing repository webhooks" {
        ^gh api $"repos/($repository)/hooks"
    } | from json)
    $hooks | where config.url == $url | get 0?
}

def notify [summary: string, body: string] {
    print --stderr $"($summary): ($body)"
    try { ^notify-send --app-name $NOTIFY_APP --urgency normal $summary $body } catch { }
}

# Create or update the GitHub workflow_run webhook for this machine's Funnel.
def main [
    endpoint?: string     # Public base URL; defaults to this machine's tailnet name
    --repository: string  # owner/name; defaults to the current checkout's repository
] {
    let base = ($endpoint | default (tailnet-endpoint))
    if $base == null {
        error make { msg: "Tailscale is not running; pass the Funnel URL or run `sudo tailscale up` first." }
    }
    let secret = (read-quiet "reading webhook secret from secretspec" {
        ^secretspec get --file $MANIFEST --provider keyring --reason "register GitHub workflow webhook" JJ_CI_WEBHOOK_SECRET
    })
    if ($secret | is-empty) {
        error make { msg: "SecretSpec returned an empty webhook secret." }
    }

    let repository = (resolve-repository $repository)
    let url = $"($base | str trim | str trim --right --char '/')($WEBHOOK_PATH)"
    let existing = (find-hook $repository $url)
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

# Send a desktop notification when the webhook needs (re)registration.
#
# Transient failures (no network, gh not authenticated) are logged without a
# notification so the reminder only fires for something setup can fix.
def "main check" [
    --repository: string  # owner/name; defaults to the current checkout's repository
] {
    let base = (tailnet-endpoint)
    if $base == null {
        notify "CI webhook offline" "Tailscale is logged out. Run `sudo tailscale up`, then `sudo systemctl start jj-ci-webhook-funnel`."
        return
    }

    let url = $"($base)($WEBHOOK_PATH)"
    let lookup = try {
        {ok: true, hook: (find-hook (resolve-repository $repository) $url)}
    } catch {|err|
        {ok: false, error: $err.msg}
    }
    if not $lookup.ok {
        print --stderr $"Skipping webhook check: ($lookup.error)"
        return
    }

    let hook = $lookup.hook
    if $hook == null {
        notify "CI webhook not registered" $"GitHub has no webhook for ($url). Run `jj-ci-webhook-setup`."
        return
    }

    let code = ($hook.last_response?.code?)
    if ($code != null) and (($code < 200) or ($code >= 300)) {
        let message = ($hook.last_response?.message? | default "no message")
        notify "CI webhook deliveries failing" $"Last delivery returned ($code): ($message). Check `jj-ci-webhook-funnel`, or run `jj-ci-webhook-setup` after rotating the secret."
        return
    }

    print $"Webhook registered for ($url)."
}
