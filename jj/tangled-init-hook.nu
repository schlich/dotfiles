# `jj git init` that also points a brand-new repository at Tangled. When the
# repository it initialized has no remotes, which leaves out existing Git
# repositories that already publish somewhere, it runs `tangled-init` there.
# `^jj git init` skips the hook.

# The directory a `jj git init` invocation initializes.
def jj-git-init-destination [args: list<string>] {
    const VALUE_FLAGS = ["--git-repo" "-R" "--repository" "--at-operation" "--at-op" "--color" "--config" "--config-file"]
    mut expecting = false
    for arg in $args {
        if $expecting { $expecting = false; continue }
        if $arg in $VALUE_FLAGS { $expecting = true; continue }
        if ($arg | str starts-with "-") { continue }
        return $arg
    }
    "."
}

@complete external
def --wrapped "jj git init" [...args: string] {
    ^jj git init ...$args
    if ($args | any {|arg| $arg in ["-h" "--help"] }) { return }
    let destination = (jj-git-init-destination $args)
    let remotes = (^jj --repository $destination git remote list | complete)
    if $remotes.exit_code == 0 and ($remotes.stdout | str trim | is-empty) {
        ^tangled-init $destination
    }
}
