# T3 Code fleet helpers (modules/tooling/ai/t3code-server.nix): thin, typed
# wrappers over `t3`, systemd and each server's discovery endpoint. The
# server does the orchestration; these only gather what it reports and pass
# work to it. $env.T3F_CONFIG names the fleet: this host, the unit, the port
# and every fleet server's tailnet URL. docs/T3-FLEET.md describes the fleet.

def t3f-config []: nothing -> record {
    let path = ($env.T3F_CONFIG? | default '')
    if ($path | is-empty) or not ($path | path exists) {
        error make {
            msg: "t3f: no fleet configuration"
            help: "This home does not run the T3 Code server (dotfiles.t3code.server)."
        }
    }
    open $path
}

# Run `t3` on HOST, here when it is this host and over ssh otherwise. ARGS
# must be plain words: ssh hands the remote side one command line.
def --wrapped t3f-t3 [host: string, ...args: string]: any -> record {
    let input = $in
    if $host == (t3f-config).self {
        $input | ^t3 ...$args | complete
    } else {
        $input | ^ssh $host t3 ...$args | complete
    }
}

# The stdout of a `complete` record, or an error carrying its stderr.
def t3f-ok [what: string]: record -> string {
    let result = $in
    if $result.exit_code != 0 {
        error make {
            msg: $"t3f: ($what) failed with exit code ($result.exit_code)"
            help: ($result.stderr | str trim)
        }
    }
    $result.stdout
}

# Commands for the T3 Code fleet: status, fleet, threads, start, send,
# show, pair, link and logs.
def t3f [] { help t3f }

# This host's T3 Code server: the unit, the version, where it answers, its
# linked environments and its T3 Connect state.
def "t3f status" []: nothing -> record {
    let config = (t3f-config)
    let unit = (^systemctl --user show $config.unit --property=ActiveState,SubState,ExecMainStartTimestamp,NRestarts | complete)
    let props = ($unit.stdout | lines | parse '{key}={value}' | transpose -r -d)
    let descriptor = (try { http get --max-time 3sec $"($config.local)/.well-known/t3/environment" } catch { null })
    let links = (^t3 environment list --json | complete)
    let connect = (^t3 connect status --json | complete)
    {
        host: $config.self
        unit: $config.unit
        state: $"($props.ActiveState? | default unknown)/($props.SubState? | default unknown)"
        since: ($props.ExecMainStartTimestamp? | default '')
        restarts: ($props.NRestarts? | default '0' | into int)
        local: $config.local
        tailnet: ($config.fleet | get -o $config.self)
        environment: $descriptor
        linked: (if $links.exit_code == 0 { $links.stdout | from json } else { $links.stderr | str trim })
        connect: (if $connect.exit_code == 0 { $connect.stdout | from json } else { $connect.stderr | str trim })
    }
}

# Which fleet servers answer now, with their version and environment id.
# --discover also asks every online Linux or macOS tailnet peer.
def "t3f fleet" [
    --discover   # Probe all online tailnet peers, not only the configured fleet
]: nothing -> table {
    let config = (t3f-config)
    let known = ($config.fleet | transpose host url)
    let peers = if $discover {
        let status = (^tailscale status --json | complete)
        if $status.exit_code != 0 { [] } else {
            $status.stdout | from json | get Peer | values
            | where { |p| $p.Online and $p.OS in [linux macOS] and ($p.DNSName | is-not-empty) }
            | each { |p| { host: $p.HostName, url: $"https://($p.DNSName | str trim --right --char '.'):($config.port)" } }
            | update host { str lowercase }
            | where { |p| $p.host not-in $known.host }
        }
    } else { [] }
    $known | append $peers | par-each --keep-order { |entry|
        let found = (try { http get --max-time 4sec $"($entry.url)/.well-known/t3/environment" } catch { null })
        {
            host: $entry.host
            url: $entry.url
            up: ($found != null)
            label: ($found.label? | default '')
            version: ($found.serverVersion? | default '')
            environment: ($found.environmentId? | default '')
        }
    }
}

# The threads of a project on this host (or --host), newest first.
def "t3f threads" [
    --project (-p): string = "."   # Project id or a path inside the project
    --host: string                 # Fleet host to ask (default: this host)
]: nothing -> table {
    let host = ($host | default (t3f-config).self)
    t3f-t3 $host thread list --project $project --json | t3f-ok "t3 thread list" | from json
}

# Start a thread and return its id; --wait returns the agent's reply. On
# another --host, PROJECT is a path or project id on that host.
def "t3f start" [
    prompt: string                 # The task for the agent
    --project (-p): string = "."   # Project id or a path inside the project
    --host: string                 # Fleet host to run on (default: this host)
    --provider: string             # Provider instance id; pass with --model
    --model: string                # Model slug (default: the project's)
    --worktree: string             # Base ref for a new git worktree (not for JJ repositories)
    --wait                         # Wait for the run and return the reply
]: nothing -> any {
    let host = ($host | default (t3f-config).self)
    let args = (
        [thread start $project - --json]
        | append (if $provider != null { [--provider $provider] } else { [] })
        | append (if $model != null { [--model $model] } else { [] })
        | append (if $worktree != null { [--worktree $worktree] } else { [] })
        | append (if $wait { [--wait] } else { [] })
    )
    $prompt | t3f-t3 $host ...$args | t3f-ok "t3 thread start" | from json
}

# Send a message to a thread; a busy thread takes it as its next turn.
def "t3f send" [
    thread: string    # Thread id
    message: string   # The message
    --host: string    # Fleet host that runs the thread (default: this host)
    --wait            # Wait for the run and return the reply
]: nothing -> any {
    let host = ($host | default (t3f-config).self)
    let args = ([thread send $thread - --json] | append (if $wait { [--wait] } else { [] }))
    $message | t3f-t3 $host ...$args | t3f-ok "t3 thread send" | from json
}

# A thread's state and its latest messages.
def "t3f show" [
    thread: string                # Thread id
    --host: string                # Fleet host that runs the thread (default: this host)
    --messages (-n): int = 10     # How many of the latest messages
]: nothing -> record {
    let host = ($host | default (t3f-config).self)
    t3f-t3 $host thread show $thread --messages ($messages | into string) --json | t3f-ok "t3 thread show" | from json
}

# Print a pairing link and QR code for a phone or another computer, at this
# server's tailnet HTTPS address. Treat the link as a password.
def "t3f pair" [
    --label: string   # Name shown in the server's connections list
    --ttl: string     # How long the link stays valid, such as 15m
]: nothing -> nothing {
    let config = (t3f-config)
    let args = (
        [pair --tailscale --tailscale-serve-port ($config.port | into string)]
        | append (if $label != null { [--label $label] } else { [] })
        | append (if $ttl != null { [--ttl $ttl] } else { [] })
    )
    ^t3 ...$args
}

# Link this environment to another fleet host, so agents here can start,
# message and wait on threads there (Settings → Labs → Linked environments
# must be on for both). Without --pairing-code it asks HOST for one over ssh.
def "t3f link" [
    host: string                             # Fleet host to link to
    --pairing-code: string                   # A code from `t3 pair` or Settings → Sharing & access there
    --access: string = "approval-required"   # read-only, approval-required, auto-accept-edits, auto, full-access
]: nothing -> string {
    let config = (t3f-config)
    let url = ($config.fleet | get -o $host)
    if $url == null {
        error make { msg: $"t3f: ($host) is not a fleet server", help: $"Known: ($config.fleet | columns | str join ', ')" }
    }
    let code = if $pairing_code != null { $pairing_code } else {
        # The code carries the scopes the access level needs (mcpClientScopes).
        let scopes = if $access == "read-only" { [--scope orchestration:read] } else if $access == "full-access" {
            [--scope orchestration:read --scope orchestration:operate --scope settings:write --scope source-control:write]
        } else { [--scope orchestration:read --scope orchestration:operate] }
        let created = (t3f-t3 $host auth pairing create ...$scopes --label $"link-from-($config.self)" --ttl 10m --json | t3f-ok $"t3 auth pairing create on ($host)" | from json)
        $created.credential
    }
    ^t3 environment link $url --pairing-code $code --access $access | complete | t3f-ok "t3 environment link"
}

# The server's journal on this host (--follow keeps reading).
def "t3f logs" [
    --follow (-f)        # Keep printing new entries
    --lines (-n): int = 100
]: nothing -> nothing {
    let config = (t3f-config)
    let args = ([--user --unit $config.unit --lines ($lines | into string) --no-pager] | append (if $follow { [--follow] } else { [] }))
    ^journalctl ...$args
}
