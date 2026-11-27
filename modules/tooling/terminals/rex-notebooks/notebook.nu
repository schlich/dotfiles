# notebook: marimo notebooks that keep running in Rex terminals, on this
# machine or on a Rex host such as homelab, opened in this machine's browser
# (modules/tooling/terminals/rex-notebooks).
#
#   notebook open                                   # this folder, here
#   notebook open ~/Research/whiteboard/notebooks/flow_matching.py
#   notebook open homelab:Research/whiteboard/notebooks
#   notebook open --on homelab ~/Research/whiteboard/notebooks --app
#   notebook ls
#   notebook log homelab:Research/whiteboard/notebooks
#   notebook stop --all
#
# A server is a Rex terminal in the session `notebooks` on the host that holds
# the files, labelled `nb:FOLDER` for `marimo edit` on a folder, which every
# notebook in it shares, or `app:PATH` for `marimo run`. notebook-serve starts
# marimo there in the project's Python environment. marimo listens only on
# that host's loopback: a host's server reaches this machine through `rex
# forward open`, kept running in a local terminal labelled `fwd:HOST:LABEL`.
#
# $env.NOTEBOOK_CONFIG names the rex command, the session, each Rex host's
# address by label, this machine's notebook-serve, and setsid.

def nb-config []: nothing -> record {
    let path = ($env.NOTEBOOK_CONFIG? | default '')
    if ($path | is-empty) or not ($path | path exists) {
        error make {
            msg: 'notebook: no configuration'
            help: 'This home has no Rex notebook commands (modules/tooling/terminals/rex-notebooks).'
        }
    }
    open $path
}

# The Rex hosts by label, for completion.
def nb-hosts []: nothing -> list<string> {
    try { (nb-config).hosts | columns } catch { [] }
}

# Whether HOST names this machine.
def nb-is-local [host: string]: nothing -> bool {
    let me = (sys host | get hostname | str lowercase)
    ($host | str lowercase) in [local localhost $me ($me | split row '.' | first)]
}

def nb-host-name [host: string]: nothing -> string {
    if (nb-is-local $host) { sys host | get hostname } else { $host }
}

# Run rex against HOST: this machine's server, or a host's by its address,
# so nothing depends on the hosts Rex keeps as runtime state.
def --wrapped nb-rex [host: string, ...args: string]: any -> record {
    let input = $in
    let config = (nb-config)
    let server = if (nb-is-local $host) { [] } else { [-S ($config.hosts | get $host)] }
    let rex = $config.rex
    $input | ^$rex ...$server ...$args | complete
}

# The stdout of a finished rex call, or an error carrying its stderr.
def nb-ok [what: string]: record -> string {
    let result = $in
    if $result.exit_code != 0 {
        error make {msg: $"notebook: ($what) failed", help: ($result.stderr | str trim)}
    }
    $result.stdout
}

# The ID of HOST's notebooks session, or null when there is none; with
# --create, a new empty one.
def nb-session [host: string, --create]: nothing -> any {
    let config = (nb-config)
    let found = (
        nb-rex $host ls --json
        | nb-ok $"rex ls on (nb-host-name $host)"
        | from json
        | get -o sessions
        | default []
        | where {|session| ($session.label? | default '') == $config.session }
        | get -o 0.session_id
    )
    if $found != null or not $create {
        return $found
    }
    {label: $config.session}
    | to json --raw
    | nb-rex $host api call session.create -
    | nb-ok $"creating the ($config.session) session on (nb-host-name $host)"
    | from json
    | get session_id
}

# The terminals in SESSION on HOST, each with its label.
def nb-terminals [host: string, session: string]: nothing -> table {
    nb-rex $host block ls -s $session --json
    | nb-ok $"rex block ls on (nb-host-name $host)"
    | from json
    | get -o blocks
    | default []
    | where {|block| ($block.creator_name? | default '') == 'com.superlogical.terminal' }
    | each {|block| $block | upsert label ($block.label? | default '') }
}

# Whether a terminal's program is `running`, `exited`, or not yet `starting`.
def nb-state [host: string, session: string, block: string]: nothing -> string {
    let result = (nb-rex $host block call -s $session -b $block process)
    if $result.exit_code != 0 {
        return 'exited'
    }
    let process = ($result.stdout | from json)
    if $process.child? != null {
        'running'
    } else if $process.last_exit? != null {
        'exited'
    } else {
        'starting'
    }
}

def nb-screen [host: string, session: string, block: string]: nothing -> string {
    nb-rex $host capture -s $session -b $block --trim --unwrap | get stdout
}

# The URL marimo printed, with its access token.
def nb-marimo-url []: string -> any {
    $in | lines | parse --regex 'URL:\s+(?<url>https?://\S+)' | get -o 0.url
}

# The local URL `rex forward open --url-only` printed.
def nb-forward-url []: string -> any {
    $in | lines | where {|line| $line =~ '^https?://\S+$' } | get -o 0
}

def nb-token [url: string]: nothing -> any {
    $url | parse --regex 'access_token=(?<token>[^&#]+)' | get -o 0.token
}

# Wait until a terminal prints a URL, as READER finds it on the screen; fail
# with the end of the screen when its program exits first or time runs out.
def nb-wait-url [
    host: string
    session: string
    block: string
    timeout: duration
    what: string
    reader: closure
]: nothing -> any {
    let deadline = ((date now) + $timeout)
    loop {
        let screen = (nb-screen $host $session $block)
        let url = ($screen | do $reader)
        if $url != null {
            return $url
        }
        let ended = (nb-state $host $session $block) == 'exited'
        if $ended or (date now) > $deadline {
            let why = if $ended { 'exited before it printed a URL' } else { $"printed no URL within ($timeout)" }
            # Read the screen again: the program's last words may follow the read above.
            let last = (nb-screen $host $session $block | lines | last 20 | str join "\n")
            error make {msg: $"notebook: ($what) ($why)", help: $last}
        }
        sleep 500ms
    }
}

def nb-tilde [path: string]: nothing -> string {
    let home = ($env.HOME | path expand)
    if $path == $home {
        '~'
    } else if ($path | str starts-with $"($home)/") {
        $"~($path | str substring ($home | str length)..)"
    } else {
        $path
    }
}

# Where TARGET lives: {host, path, dir}. HOST:PATH names a configured Rex host
# or this machine, --on names the host of a plain path, and any other path is
# on this machine. A host's path stays as given, with `~` for the host to
# expand and a relative path under its home, as scp reads it; a name ending
# in .py or .md is a notebook there and anything else a folder.
def nb-target [target: string, on: any, --exists]: nothing -> record<host: string, path: string, dir: bool> {
    let hosts = ((nb-config).hosts | columns)
    let named = ($target | parse --regex '^(?<host>[A-Za-z0-9][A-Za-z0-9.-]*):(?<path>.*)$' | get -o 0)
    let prefixed = $named != null and (($named.host in $hosts) or (nb-is-local $named.host))
    if $prefixed and $on != null and $named.host != $on {
        error make {msg: $"notebook: ($target) names ($named.host), but --on names ($on)"}
    }
    let host = if $prefixed { $named.host } else { $on | default local }
    let raw = if $prefixed { $named.path } else { $target }
    if (nb-is-local $host) {
        let path = (if ($raw | is-empty) { '.' } else { $raw } | path expand)
        let present = ($path | path exists)
        if $exists and not $present {
            error make {msg: $"notebook: ($raw) does not exist here"}
        }
        let dir = if $present { ($path | path type) == dir } else { not ($path =~ '\.(py|md)$') }
        return {host: local, path: (nb-tilde $path), dir: $dir}
    }
    if $host not-in $hosts {
        error make {msg: $"notebook: no Rex host named ($host)", help: $"Rex hosts: ($hosts | str join ', ')"}
    }
    let trimmed = ($raw | str trim | str replace --regex '(.)/+$' '$1' | str replace --regex '^\./' '')
    let path = if ($trimmed | is-empty) or $trimmed in ['~' '.'] {
        '~'
    } else if ($trimmed | str starts-with '/') or ($trimmed | str starts-with '~/') {
        $trimmed
    } else {
        $"~/($trimmed)"
    }
    {host: $host, path: $path, dir: (not ($path =~ '\.(py|md)$'))}
}

# The server that serves TARGET: in edit mode the notebook's folder, so a
# folder's notebooks share one server and kernel environment; with --app,
# TARGET itself. FILE is the notebook to open in a folder's server.
def nb-key [target: record, app: bool]: nothing -> record<label: string, served: string, file: any> {
    if $app {
        return {label: $"app:($target.path)", served: $target.path, file: null}
    }
    if $target.dir {
        return {label: $"nb:($target.path)", served: $target.path, file: null}
    }
    let folder = ($target.path | path dirname)
    {label: $"nb:($folder)", served: $folder, file: ($target.path | path basename)}
}

# The running server on HOST that can open KEY: its own, or for a notebook the
# server of the nearest folder above it. Returns {block, file}, FILE relative
# to that server's folder, or null.
def nb-find [host: string, session: string, key: record]: nothing -> any {
    let terminals = (nb-terminals $host $session)
    let candidates = if $key.file == null {
        $terminals | where label == $key.label | each {|terminal| {block: $terminal.block_id, file: null} }
    } else {
        let notebook = $"($key.served)/($key.file)"
        $terminals
        | where {|terminal| $terminal.label starts-with 'nb:' }
        | each {|terminal| {block: $terminal.block_id, folder: ($terminal.label | str substring 3..)} }
        | where {|server| $notebook | str starts-with $"($server.folder)/" }
        | sort-by --reverse {|server| $server.folder | str length }
        | each {|server| {block: $server.block, file: ($notebook | str substring (($server.folder | str length) + 1)..)} }
    }
    $candidates | where {|server| (nb-state $host $session $server.block) == 'running' } | get -o 0
}

# Close LABEL's terminals on HOST with the forwards that reach them here.
def nb-close [host: string, session: string, label: string]: nothing -> int {
    let terminals = (nb-terminals $host $session | where label == $label)
    let ports = (
        $terminals
        | each {|terminal| nb-screen $host $session $terminal.block_id | nb-marimo-url }
        | compact
        | each {|url| $url | url parse | get port }
    )
    nb-close-forwards $host $label
    for terminal in $terminals {
        nb-rex $host block close -s $session $terminal.block_id | ignore
    }
    # A forward killed rather than stopped leaves its tunnel block on the host.
    if not (nb-is-local $host) and ($ports | is-not-empty) {
        let tunnels = (
            nb-rex $host forward ls -s $session --json
            | nb-ok $"rex forward ls on ($host)"
            | from json
            | get -o forwards
            | default []
            | where {|forward| ($forward.connect? | default '' | split row ':' | last) in $ports }
            | get block_id
        )
        if ($tunnels | is-not-empty) {
            nb-rex $host forward close -s $session ...$tunnels | ignore
        }
    }
    $terminals | length
}

# Stop the local forwards to LABEL on HOST: Ctrl-C lets each close its tunnel
# block on the host before its terminal goes.
def nb-close-forwards [host: string, label: string]: nothing -> nothing {
    let session = (nb-session local)
    if $session == null {
        return
    }
    let forwards = (nb-terminals local $session | where label == $"fwd:($host):($label)")
    for forward in $forwards {
        nb-rex local send-key -s $session -b $forward.block_id ctrl+c | ignore
    }
    for forward in $forwards {
        for _ in 1..20 {
            if (nb-state local $session $forward.block_id) != 'running' {
                break
            }
            sleep 100ms
        }
        nb-rex local block close -s $session $forward.block_id | ignore
    }
}

# A URL here for marimo's URL on HOST: a `rex forward open` in a local
# terminal, reused while it still reaches the same server.
def nb-forward [host: string, label: string, url: string, timeout: duration]: nothing -> string {
    let config = (nb-config)
    let session = (nb-session local --create)
    let name = $"fwd:($host):($label)"
    let token = (nb-token $url)
    let live = (
        nb-terminals local $session
        | where label == $name
        | each {|forward| {block: $forward.block_id, url: (nb-screen local $session $forward.block_id | nb-forward-url)} }
        | where {|forward| $forward.url != null and (nb-token $forward.url) == $token and (nb-state local $session $forward.block) == 'running' }
        | get -o 0.url
    )
    if $live != null {
        return $live
    }
    nb-close-forwards $host $label
    let created = (
        nb-rex local run -s $session --label $name --keep-open --focus=false --json -- $config.rex -S ($config.hosts | get $host) forward open -s $config.session --url-only $url
        | nb-ok 'rex run (the forward)'
        | from json
    )
    nb-wait-url local $session ($created.block_ids | first) $timeout $"the forward to ($host)" {|| $in | nb-forward-url }
}

def nb-with-file [url: string, file: any]: nothing -> string {
    if $file == null {
        return $url
    }
    let separator = if ($url | str contains '?') { '&' } else { '?' }
    $"($url)($separator)file=($file | url encode --all)"
}

# Open URL in this machine's browser, apart from this terminal; false when the
# session has no display or no xdg-open.
def nb-browse [url: string]: nothing -> bool {
    if ($env.WAYLAND_DISPLAY? | is-empty) and ($env.DISPLAY? | is-empty) {
        return false
    }
    let opener = (which xdg-open | get -o 0.path)
    if $opener == null {
        return false
    }
    let setsid = (nb-config).setsid
    ^$setsid --fork $opener $url o+e> /dev/null
    true
}

# marimo notebooks in Rex terminals, here or on a Rex host such as homelab,
# opened in this machine's browser. See `notebook open`.
def notebook [] {
    help notebook
}

# Open a marimo notebook, or a folder of them, in this machine's browser. The
# first open starts its server in a Rex terminal on the host that holds the
# files, in the project's Python environment, and later opens reuse it. TARGET
# is a path here, or HOST:PATH on a Rex host, where a relative path starts at
# the home folder. Edit mode serves a notebook's folder, so its other
# notebooks open in the same server.
def --wrapped "notebook open" [
    target: string = '.' # notebook file or folder; HOST:PATH for a Rex host
    --on: string@nb-hosts # the Rex host that holds TARGET
    --app # run it read-only as an app (marimo run)
    --restart # start a new server for TARGET's own folder in place of a running one
    --no-browser # return the URL without opening it
    --timeout: duration = 5min # how long marimo may take to print its URL
    ...marimo: string # options for marimo when it starts a server, such as --watch
]: nothing -> record {
    let target = (nb-target $target $on --exists)
    let key = (nb-key $target $app)
    let host = $target.host
    let session = (nb-session $host --create)
    let found = if $restart { null } else { nb-find $host $session $key }
    let server = if $found != null {
        $found
    } else {
        # A server that exited keeps its terminal, so its output stays
        # readable until a new one replaces it.
        nb-close $host $session $key.label | ignore
        print --stderr $"notebook: starting marimo for ($key.served) on (nb-host-name $host)"
        let config = (nb-config)
        let serve = if (nb-is-local $host) { $config.serve } else { 'notebook-serve' }
        let mode = if $app { [--app] } else { [] }
        let created = (
            nb-rex $host run -s $session --label $key.label --keep-open --focus=false --json -- $serve $key.served ...$mode ...$marimo
            | nb-ok $"rex run on (nb-host-name $host)"
            | from json
        )
        {block: ($created.block_ids | first), file: $key.file, started: true}
    }
    let served = (nb-wait-url $host $session $server.block $timeout $"marimo for ($key.served)" {|| $in | nb-marimo-url })
    let label = (nb-terminals $host $session | where block_id == $server.block | get -o 0.label | default $key.label)
    let reachable = if (nb-is-local $host) { $served } else { nb-forward $host $label $served 1min }
    let url = (nb-with-file $reachable $server.file)
    let opened = if $no_browser { false } else { nb-browse $url }
    {
        host: (nb-host-name $host)
        path: $target.path
        url: $url
        started: ($server.started? | default false)
        opened: $opened
    }
}

# The notebook servers here and on every Rex host that answers, with the URL
# to open each one from here.
def "notebook ls" []: nothing -> table {
    let remote = (nb-hosts | where {|host| not (nb-is-local $host) })
    let local = (nb-session local)
    let forwards = if $local == null {
        []
    } else {
        nb-terminals local $local
        | where {|terminal| $terminal.label starts-with 'fwd:' }
        | each {|forward| $forward | insert url (nb-screen local $local $forward.block_id | nb-forward-url) | insert state (nb-state local $local $forward.block_id) }
    }
    [local ...$remote]
    | par-each --keep-order {|host|
        let session = (try { nb-session $host } catch {|err| print --stderr $"notebook: (nb-host-name $host) did not answer: ($err.msg)"; null })
        if $session == null {
            []
        } else {
            nb-terminals $host $session
            | where {|terminal| $terminal.label =~ '^(nb|app):' }
            | each {|terminal|
                let state = (nb-state $host $session $terminal.block_id)
                let url = if (nb-is-local $host) {
                    nb-screen $host $session $terminal.block_id | nb-marimo-url
                } else {
                    $forwards | where label == $"fwd:($host):($terminal.label)" and state == 'running' | get -o 0.url
                }
                {
                    host: (nb-host-name $host)
                    kind: (if ($terminal.label starts-with 'app:') { 'app' } else { 'edit' })
                    path: ($terminal.label | str replace --regex '^(nb|app):' '')
                    state: $state
                    url: (if $state == 'running' { $url } else { null })
                }
            }
        }
    }
    | flatten
}

# The terminal of TARGET's notebook server: which environment notebook-serve
# chose, and marimo's output and tracebacks.
def "notebook log" [
    target: string = '.' # notebook file or folder, or HOST:PATH
    --on: string@nb-hosts # the Rex host that holds TARGET
    --app # the app server for TARGET rather than its editor
]: nothing -> string {
    let target = (nb-target $target $on)
    let key = (nb-key $target $app)
    let session = (nb-session $target.host)
    let terminal = if $session == null { null } else { nb-terminals $target.host $session | where label == $key.label | get -o 0 }
    if $terminal == null {
        error make {msg: $"notebook: no server for ($key.served) on (nb-host-name $target.host)"}
    }
    nb-screen $target.host $session $terminal.block_id
}

# Stop TARGET's notebook server, or with --all every one, and the forwards
# that reach them from here.
def "notebook stop" [
    target?: string # notebook file or folder, or HOST:PATH
    --on: string@nb-hosts # the Rex host that holds TARGET
    --app # the app server for TARGET rather than its editor
    --all # every notebook server here and on every Rex host
]: nothing -> table {
    let servers = if $all {
        notebook ls | each {|server| {host: $server.host, label: $"(if $server.kind == 'app' { 'app' } else { 'nb' }):($server.path)"} }
    } else {
        if $target == null {
            error make {msg: 'notebook stop: name a notebook or folder, or pass --all'}
        }
        let resolved = (nb-target $target $on)
        [{host: $resolved.host, label: (nb-key $resolved $app).label}]
    }
    let stopped = (
        $servers
        | each {|server|
            let host = if (nb-is-local $server.host) { 'local' } else { $server.host }
            let session = (nb-session $host)
            let closed = if $session == null { 0 } else { nb-close $host $session $server.label }
            {host: (nb-host-name $host), path: ($server.label | str replace --regex '^(nb|app):' ''), stopped: ($closed > 0)}
        }
    )
    if $all {
        # Forwards whose server is already gone.
        let local = (nb-session local)
        if $local != null {
            nb-terminals local $local
            | where {|terminal| $terminal.label starts-with 'fwd:' }
            | each {|forward| nb-rex local block close -s $local $forward.block_id }
            | ignore
        }
    } else if not ($stopped | any {|server| $server.stopped }) {
        error make {msg: $"notebook: no server for ($target) to stop"}
    }
    $stopped
}

# Open a notebook or folder: `notebook open`.
alias nb = notebook open
