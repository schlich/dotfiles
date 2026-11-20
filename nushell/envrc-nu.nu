# Load a project's `.envrc.nu` into the interactive shell as the `envrc`
# overlay, after direnv has loaded that project.
#
# direnv hands Nushell environment variables only. A project that also wants
# Nushell commands, aliases, or completions in the shell keeps them in a
# module named `.envrc.nu` beside its `.envrc`. When direnv loads the project,
# DIRENV_DIR names its root, and this hook activates that root's `.envrc.nu`
# as the `envrc` overlay. It hides the overlay when direnv unloads the project
# or loads another one.
#
# Trust works like direnv's allow list, per file content: a module loads only
# after `envrc-nu allow` has approved its exact contents, so a new or edited
# `.envrc.nu` stays blocked, with a one-line notice, until it is allowed.
#
# The overlay loads a private copy of the approved contents, so a relative
# `use` or `source` inside `.envrc.nu` does not resolve: keep the module
# self-contained. The default overlay goes back on top after loading, so
# variables set at the prompt outlive the project. A module that uses
# `export-env` is refused: Nushell gives its overlay a copy of the whole
# environment, which would mask direnv's later changes, including the unload
# when you leave. Put the environment in `.envrc` and the Nushell definitions
# here. A variable hidden with `hide-env` while the overlay is loaded comes
# back when the overlay unloads.

const ENVRC_NU_FILE = ".envrc.nu"

# Approvals: one file per approved (path, contents) pair, named by their
# hash and holding the path. ENVRC_NU_ALLOW_DIR overrides it for tests.
def envrc-nu-allow-dir [] {
    $env.ENVRC_NU_ALLOW_DIR? | default ($nu.data-dir | path join envrc-nu allow)
}

def envrc-nu-key [file: path, contents: string] {
    $"($file)\n($contents | hash sha256)" | hash sha256
}

def envrc-nu-show [file: path] {
    $file | str replace $nu.home-dir "~"
}

# The project root direnv has loaded, from DIRENV_DIR ("-/path/to/root").
def envrc-nu-root [] {
    let dir = ($env.DIRENV_DIR? | default "")
    if ($dir | is-empty) { null } else { $dir | str replace --regex "^-" "" }
}

# The `.envrc.nu` at `root`, with its contents and whether they are allowed,
# or null when the root has none.
export def envrc-nu-offer [root?: path] {
    if $root == null { return null }
    let file = ($root | path join $ENVRC_NU_FILE)
    if ($file | path type) != "file" { return null }
    let contents = (open --raw $file | into string)
    {
        root: $root
        file: $file
        contents: $contents
        sha: ($contents | hash sha256)
        allowed: (envrc-nu-allow-dir | path join (envrc-nu-key $file $contents) | path exists)
        exports_env: ($contents =~ '\bexport-env\b')
    }
}

# What to do about the overlay: "load", "unload", "reload", or "".
export def envrc-nu-action [loaded?: record, offer?: record] {
    let want = if $offer != null and $offer.allowed and not $offer.exports_env { $offer }
    let same = (
        $loaded != null and $want != null
        and $loaded.root == $want.root and $loaded.sha == $want.sha
    )
    match [($loaded != null and not $same) ($want != null and not $same)] {
        [true true] => "reload"
        [true false] => "unload"
        [false true] => "load"
        _ => ""
    }
}

def envrc-nu-active [] {
    "envrc" in (overlay list | where active | get name)
}

# Whether the shell has left the root of the loaded module. Checked before
# direnv's hook: a variable that direnv hides while the overlay is active
# comes back when the overlay is hidden later in the same prompt, so the
# overlay goes first.
def envrc-nu-leaving [] {
    let root = $env.ENVRC_NU_ROOT?
    if $root == null or not (envrc-nu-active) { return false }
    let root = ($root | path expand)
    let here = ($env.PWD | path expand)
    $here != $root and not ($here | str starts-with $"($root)/")
}

# After the overlay is hidden, forget which module it held.
def --env envrc-nu-forget [] {
    if $env.ENVRC_NU_ROOT? != null and not (envrc-nu-active) {
        hide-env --ignore-errors ENVRC_NU_ROOT ENVRC_NU_SHA
        print --stderr "envrc-nu: unloading"
    }
}

# Runs after direnv's hook: decide, stage the approved contents at `active`,
# and leave the decision in ENVRC_NU_ACTION for the overlay hooks that follow.
# It decides again only when this shell sees a new DIRENV_DIR or
# ENVRC_NU_STAMP.
def --env envrc-nu-plan [active: path] {
    let seen = $"($nu.pid) ($env.DIRENV_DIR? | default '') ($env.ENVRC_NU_STAMP? | default '')"
    if $env.ENVRC_NU_SEEN? == $seen { return }
    $env.ENVRC_NU_SEEN = $seen

    let loaded = if (envrc-nu-active) and $env.ENVRC_NU_ROOT? != null {
        {root: $env.ENVRC_NU_ROOT, sha: $env.ENVRC_NU_SHA?}
    }
    let offer = (envrc-nu-offer (envrc-nu-root))
    let action = (envrc-nu-action $loaded $offer)
    $env.ENVRC_NU_ACTION = $action

    if $action in [load reload] {
        mkdir ($active | path dirname)
        $offer.contents | save --force $active
        $env.ENVRC_NU_ROOT = $offer.root
        $env.ENVRC_NU_SHA = $offer.sha
        print --stderr $"envrc-nu: loading (envrc-nu-show $offer.file)"
    }
    if $offer != null and not $offer.allowed {
        print --stderr $"envrc-nu: (envrc-nu-show $offer.file) is blocked. Run `envrc-nu allow` to approve its content."
    } else if $offer != null and $offer.exports_env {
        print --stderr $"envrc-nu: (envrc-nu-show $offer.file) uses export-env, so it is not loaded. Put environment variables in .envrc."
    }
}

# The `.envrc.nu` a command acts on: the given file, the one in the given
# directory, the one at the root direnv has loaded, or the nearest one above
# the current directory.
def envrc-nu-locate [target?: path] {
    let file = if $target != null {
        let target = ($target | path expand)
        if ($target | path type) == "dir" { $target | path join $ENVRC_NU_FILE } else { $target }
    } else if (envrc-nu-root) != null {
        envrc-nu-root | path join $ENVRC_NU_FILE
    } else {
        mut dir = $env.PWD
        loop {
            if ($dir | path join $ENVRC_NU_FILE | path type) == "file" { break }
            let parent = ($dir | path dirname)
            if $parent == $dir { break }
            $dir = $parent
        }
        $dir | path join $ENVRC_NU_FILE
    }
    if ($file | path type) != "file" {
        error make {msg: $"no ($ENVRC_NU_FILE) found (if $target == null { 'for this directory' } else { $'at ($target)' })"}
    }
    $file
}

# Load a project's .envrc.nu as the `envrc` overlay after direnv loads the
# project. Subcommands approve, revoke, and inspect it.
export def envrc-nu [] {
    help envrc-nu
}

# Approve a .envrc.nu, as its contents are now, and load it at the next prompt.
export def --env "envrc-nu allow" [
    target?: path # the .envrc.nu, or its directory; default: the current project's
] {
    let file = (envrc-nu-locate $target)
    let contents = (open --raw $file | into string)
    if $contents =~ '\bexport-env\b' {
        error make {msg: $"(envrc-nu-show $file) uses export-env, which envrc-nu does not load. Put environment variables in .envrc."}
    }
    let dir = (envrc-nu-allow-dir)
    mkdir $dir
    $file | save --force ($dir | path join (envrc-nu-key $file $contents))
    $env.ENVRC_NU_STAMP = (random uuid)
}

# Revoke every approval of a .envrc.nu and unload it at the next prompt.
export def --env "envrc-nu deny" [
    target?: path # the .envrc.nu, or its directory; default: the current project's
] {
    let file = (envrc-nu-locate $target)
    let dir = (envrc-nu-allow-dir)
    if ($dir | path exists) {
        ls $dir | where {|entry| (open --raw $entry.name | into string) == $file } | each {|entry| rm $entry.name } | ignore
    }
    $env.ENVRC_NU_STAMP = (random uuid)
}

# The current project's .envrc.nu: where it is, whether it is allowed, and
# whether the `envrc` overlay holds it.
export def "envrc-nu status" [] {
    let offer = (envrc-nu-offer (envrc-nu-root))
    {
        root: (envrc-nu-root)
        file: $offer.file?
        allowed: $offer.allowed?
        loaded: ((envrc-nu-active) and $env.ENVRC_NU_ROOT? == (envrc-nu-root))
    }
}

# Wrap the `pre_prompt` hooks. Call this after direnv's own prompt hook is
# installed. Leaving a project's root unloads its overlay before direnv's
# hook runs; everything else runs after it, reading the DIRENV_DIR that
# direnv has just set on the same prompt. (An `env_change` hook on DIRENV_DIR
# would lag a prompt, because Nushell checks `env_change` before it runs
# `pre_prompt`.)
#
# The overlay commands run as string hooks because `overlay use` needs its
# path when the code is parsed; `active` is this shell's own copy of the
# approved module.
export def --env setup-envrc-nu [] {
    let active = ($nu.cache-dir | path join envrc-nu $"active-($nu.pid).nu")
    let before_direnv = [
        {condition: {|| envrc-nu-leaving }, code: "overlay hide envrc"}
        {|| envrc-nu-forget }
    ]
    let after_direnv = [
        {|| envrc-nu-plan $active }
        {
            condition: {|| $env.ENVRC_NU_ACTION? in [unload reload] }
            code: "overlay hide envrc"
        }
        {
            condition: {|| $env.ENVRC_NU_ACTION? in [load reload] }
            code: $"overlay use --reload '($active)' as envrc\noverlay use zero\nrm --force '($active)'"
        }
        {|| hide-env --ignore-errors ENVRC_NU_ACTION; envrc-nu-forget }
    ]
    $env.config.hooks.pre_prompt = (
        $before_direnv
        | append ($env.config.hooks.pre_prompt? | default [])
        | append $after_direnv
    )
}
