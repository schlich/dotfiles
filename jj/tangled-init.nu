# Point a new JJ repository at Tangled the way `ci` expects: a `tangled`
# remote for schlich.tngl.sh/NAME that the repository pushes to, fetches from,
# and takes its trunk from. It sets no `ci.enable`, so the repository uses
# plain jj until it opts into ci (jj/README.md). The settings go in the
# repository's own JJ config, because JJ cannot scope global config by remote.
# Creating the repository on Tangled needs a signed-in session, so this only
# reports whether it exists.

const OWNER = "schlich.tngl.sh"
const OWNER_DID = "did:plc:cnyy2sz5ddr4gls245vjgbrd"
const INDEX = "https://api.tangled.org/xrpc"
const REMOTE = "tangled"
# Until main reaches Tangled, trunk() falls back to the root commit instead of
# failing every command that resolves it.
const TRUNK = "coalesce(present(main@tangled), root())"

def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed: ($result.stderr | str trim)" }
    }
    $result.stdout | str trim
}

def main [
    directory: path = "."  # A directory in the repository; one without a JJ repository is initialized colocated.
    --name: string         # The repository's name on Tangled; defaults to the repository directory's name.
] {
    cd $directory
    let found = (^jj root | complete)
    let root = if $found.exit_code == 0 { $found.stdout | str trim } else { pwd }
    let name = ($name | default ($root | path basename))
    if $name !~ '^[A-Za-z0-9._-]+$' {
        error make { msg: $"`($name)` is not a Tangled repository name; pass one with --name." }
    }
    if $found.exit_code != 0 {
        run-command "initializing a colocated JJ repository" { ^jj git init --colocate }
    }
    cd $root

    let url = $"git@tangled.org:($OWNER)/($name)"
    let remotes = (run-command "listing remotes" { ^jj git remote list } | lines | parse "{name} {url}")
    let current = ($remotes | where name == $REMOTE | get --optional 0.url)
    if $current == null {
        run-command $"adding the ($REMOTE) remote" { ^jj git remote add $REMOTE $url }
    } else if $current != $url {
        print --stderr $"Keeping the existing ($REMOTE) remote, ($current), instead of ($url)."
    }
    let fetch = ([$REMOTE] | append ($remotes | where name == "origin" | get name))
    run-command "setting the push remote" { ^jj config set --repo git.push $REMOTE }
    run-command "setting the fetch remotes" { ^jj config set --repo git.fetch ($fetch | to json --raw) }
    run-command "setting trunk()" { ^jj config set --repo 'revset-aliases."trunk()"' $TRUNK }
    print $"($root) pushes to and takes its trunk from ($REMOTE): ($current | default $url)."

    let record = (try {
        http get --full --allow-errors $"($INDEX)/sh.tangled.repo.getRepo?repo=at://($OWNER_DID)/sh.tangled.repo/($name)"
    } catch { null })
    if $record == null {
        print "Could not reach the Tangled index to check whether the repository exists."
    } else if $record.status == 200 {
        print $"($OWNER)/($name) is on Tangled."
    } else {
        print $"($OWNER)/($name) is not on Tangled yet. Create it at https://tangled.org/repo/new, then push main:"
        print $"  jj bookmark set main -r @-; jj bookmark track main@($REMOTE); jj git push --remote ($REMOTE) --bookmark main"
    }
}
