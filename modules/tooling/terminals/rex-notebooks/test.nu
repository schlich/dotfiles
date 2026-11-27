# The notebook commands against two private Rex servers, one standing in for
# this machine and one for a Rex host named `far`, with a stand-in marimo
# that serves the folder over HTTP and prints marimo's URL line. The check in
# default.nix appends this file to notebook.nu and runs it, with
# notebook-serve built around the stand-in on PATH.
use std/assert

# Fetch URL, spelling localhost as the address the stand-ins listen on.
def fetch [url: string]: nothing -> int {
    http get --full --raw ($url | str replace 'localhost' '127.0.0.1') | get status
}

# The environment that gives rex a server of its own under DIR.
def private-server [dir: path]: nothing -> record {
    {
        REX_RUNTIME_DIR: ($dir | path join run)
        XDG_STATE_HOME: ($dir | path join state)
        XDG_CONFIG_HOME: ($dir | path join config)
    }
}

# What notebook-serve would start for TARGET.
def --wrapped plan [target: path, ...args: string]: nothing -> record {
    ^notebook-serve --dry-run $target ...$args | from json
}

# notebook-serve's environment rules, without a server.
def check-plans [root: path] {
    let uv = ($root | path join uv sub)
    mkdir $uv
    "[project]\nname = 'uv'\nversion = '0'\ndependencies = ['marimo>=0.25', 'numpy']\n" | save ($root | path join uv pyproject.toml)
    let plan = (plan $uv)
    assert equal $plan.environment 'uv project'
    assert equal $plan.root ($root | path join uv)
    assert equal ($plan.command | first 4) [uv run marimo edit]
    assert equal ($plan.command | last) $uv
    assert ('--no-sandbox' in $plan.command)

    let bare = ($root | path join bare)
    mkdir $bare
    "[project]\nname = 'bare'\nversion = '0'\n[dependency-groups]\ndev = ['pytest']\n" | save ($bare | path join pyproject.toml)
    assert equal ((plan $bare).command | first 5) [uv run --with marimo marimo]

    let pixi = ($root | path join pixi)
    mkdir $pixi
    '[workspace]' | save ($pixi | path join pixi.toml)
    assert equal ((plan $pixi).command | first 4) [pixi run marimo edit]

    let script = ($root | path join script)
    mkdir $script
    "# /// script\n# dependencies = ['marimo']\n# ///\nimport marimo\n" | save ($script | path join inline.py)
    let plan = (plan $script)
    assert equal $plan.environment 'PEP 723 sandbox'
    assert ('--sandbox' in $plan.command)

    let plain = ($root | path join plain)
    mkdir $plain
    'import marimo' | save ($plain | path join one.py)
    let plan = (plan ($plain | path join one.py) --watch)
    assert equal $plan.environment 'nix'
    # A notebook's folder is served, so its neighbours share the server.
    assert equal ($plan.command | last 2) [--watch $plain]
    let app = (plan ($plain | path join one.py) --app)
    assert equal ($app.command | skip 1 | first 3) [run --headless --token]
    assert equal ($app.command | last) ($plain | path join one.py)
}

def main [] {
    let root = (mktemp --directory --tmpdir rex-notebooks.XXXXXX)
    let far_env = (private-server ($root | path join far))
    let here_env = (private-server ($root | path join here))
    mkdir $far_env.REX_RUNTIME_DIR $here_env.REX_RUNTIME_DIR
    let stop = {||
        with-env $far_env { ^rex server stop | complete | ignore }
        with-env $here_env { ^rex server stop | complete | ignore }
        rm --recursive --force $root
    }

    try {
        check-plans ($root | path join plans)

        # The first rex command starts each server; `far` is reached by its
        # address, as a Rex host is.
        let far = (with-env $far_env { ^rex whoami --json | from json | get endpoint })
        load-env $here_env
        {
            rex: (which rex | get 0.path)
            session: notebooks
            hosts: {far: $far}
            serve: (which notebook-serve | get 0.path)
            setsid: setsid
        } | save ($root | path join notebook.json)
        $env.NOTEBOOK_CONFIG = ($root | path join notebook.json)

        let here = ($root | path join project)
        let there = ($root | path join remote)
        mkdir ($here | path join sub) $there
        'import marimo' | save ($here | path join first.py)
        'import marimo' | save ($here | path join sub second.py)
        'import marimo' | save ($there | path join third.py)

        # A folder starts a server here, which answers at the URL returned.
        let opened = (notebook open $here --no-browser)
        assert $opened.started
        assert ($opened.url =~ '^http://localhost:\d+\?access_token=')
        assert equal (fetch $opened.url) 200

        # Opening it again reuses the server, and a notebook below the folder
        # opens in it too.
        let again = (notebook open $here --no-browser)
        assert (not $again.started)
        assert equal $again.url $opened.url
        let nested = (notebook open ($here | path join sub second.py) --no-browser)
        assert (not $nested.started)
        assert equal $nested.url $"($opened.url)&file=sub%2Fsecond%2Epy"

        # A host's folder starts a server there and a forward here, and both
        # ways of naming the host find the same server.
        let remote = (notebook open $"far:($there)" --no-browser)
        assert $remote.started
        assert equal $remote.host far
        assert ($remote.url =~ '^http://localhost:\d+\?access_token=')
        assert equal (fetch $remote.url) 200
        let same = (notebook open --on far ($there | path join third.py) --no-browser)
        assert (not $same.started)
        assert equal $same.url $"($remote.url)&file=third%2Epy"

        # ls lists both, with the URL to open each from here.
        let servers = (notebook ls)
        assert equal ($servers | where state == running | length) 2
        assert equal ($servers | where host == far | get url) [$remote.url]

        # A path the host lacks fails with notebook-serve's own message, and
        # its terminal stays for `notebook log`.
        let missing = $"far:($root)/missing"
        let failure = (try { notebook open $missing --no-browser; null } catch {|err| $err.details })
        assert ($failure != null)
        assert str contains $failure.msg 'exited before it printed a URL'
        assert str contains $failure.help 'no such file or folder'
        assert str contains (notebook log $missing) 'no such file or folder'

        # A restart replaces the server, and the forward follows it.
        let restarted = (notebook open --restart $"far:($there)" --no-browser)
        assert $restarted.started
        assert not equal $restarted.url $remote.url
        assert equal (fetch $restarted.url) 200

        # stop takes a server with its forward; --all takes the rest.
        let stopped = (notebook stop $here)
        assert equal $stopped.0.stopped true
        assert equal (notebook ls | where host != far | length) 0
        notebook stop --all | ignore
        assert equal (notebook ls | length) 0
        let forwards = (^rex block ls -s notebooks --json | from json | get -o blocks | default [] | where {|block| ($block.label? | default '') starts-with 'fwd:' })
        assert equal ($forwards | length) 0
        let tunnels = (^rex -S $far forward ls -s notebooks --json | from json | get -o forwards | default [])
        assert equal ($tunnels | length) 0
    } catch {|err|
        do $stop
        error make {msg: $err.msg}
    }
    do $stop
    print 'notebook: ok'
}
