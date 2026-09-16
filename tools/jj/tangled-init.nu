def run [label: string, command: closure] {
    let result = (do $command | complete)
    if $result.exit_code != 0 { error make { msg: $"($label) failed: ($result.stderr | str trim)" } }
    $result.stdout | str trim
}

def main [remote_url: string] {
    let root = (run "locating JJ root" { ^jj root })
    let git_root = (run "locating Git backend" { ^jj git root })
    if $root != $git_root {
        print "This is a non-colocated JJ workspace; Git interoperability still works through its backend."
    }
    let remotes = (run "listing remotes" { ^jj git remote list })
    if ($remotes | lines | any {|line| $line | str starts-with "tangled " }) {
        run "updating Tangled remote" { ^jj git remote set-url tangled $remote_url } | ignore
    } else {
        run "adding Tangled remote" { ^jj git remote add tangled $remote_url } | ignore
    }
    print "Tangled remote configured; origin was not changed."
    print (run "verifying Tangled connection" { ^jj git fetch --remote tangled })
    print "Relevant bookmarks:"
    ^jj bookmark list
    print "Change-ID propagation for @:"
    print (run "reading current change" { ^jj log -r @ --no-graph -T 'change_id ++ " -> " ++ commit_id' })
    print "Enrollment is complete. No push was performed. Use `jj-stack push` when ready."
}
