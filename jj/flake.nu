def run-command [label: string, command: closure] {
    let result = (do $command | complete)

    if ($result.stdout | is-not-empty) {
        print --no-newline $result.stdout
    }
    if ($result.stderr | is-not-empty) {
        print --stderr --no-newline $result.stderr
    }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }

    $result.stdout | str trim
}

def current-change [template: string] {
    ^jj log -r @ --no-graph -T $template | str trim
}

def ensure-flake-change [] {
    let changed_files = (^jj diff --name-only | lines | where { $in | is-not-empty })

    if $changed_files != ["flake.lock"] {
        error make {
            msg: $"Expected only flake.lock to change; found: ($changed_files | str join ', ')"
        }
    }
}

def sync-main [] {
    run-command "jj git fetch" { ^jj git fetch --remote origin } | ignore
    run-command "updating the main bookmark" {
        ^jj bookmark set main -r main@origin --allow-backwards
    } | ignore

    if (current-change "empty") == "true" {
        run-command "rebasing the empty working copy" {
            ^jj rebase -r @ -o main@origin
        } | ignore
    }
}

def start-follow-up-change [] {
    run-command "starting a follow-up change" { ^jj new @ } | ignore
    print "Started a fresh follow-up change. Subsequent edits will not rewrite the published revision."
}

def publish-change [merge: bool] {
    ensure-flake-change

    let title = (current-change "description.first_line()")
    if ($title | is-empty) {
        error make { msg: "Describe the change before publishing it" }
    }

    let change_id = (current-change "change_id.short()")
    let commit_id = (current-change "commit_id")
    let branch = $"flake-update/($change_id)"

    run-command "setting the update bookmark" {
        ^jj bookmark set $branch -r @
    } | ignore
    run-command "pushing the update bookmark" {
        ^jj git push --remote origin --bookmark $branch
    } | ignore

    let existing_pr = (do {
        ^gh pr view $branch --json url --jq .url
    } | complete)
    let pr_url = if $existing_pr.exit_code == 0 {
        $existing_pr.stdout | str trim
    } else {
        run-command "creating the pull request" {
            (^gh pr create
              --base main
              --head $branch
              --title $title
              --body "## Summary\n\n- update pinned flake inputs\n\n## Validation\n\n- `nix flake check`")
        }
    }

    print $pr_url

    if $merge {
        run-command "waiting for pull request checks" {
            ^gh pr checks $pr_url --watch
        } | ignore
        run-command "merging the pull request" {
            ^gh pr merge $pr_url --squash --delete-branch --match-head-commit $commit_id
        } | ignore
        run-command "deleting the local update bookmark" {
            ^jj bookmark delete $branch
        } | ignore
        sync-main
        run-command "starting a fresh change" { ^jj new main@origin } | ignore
    } else {
        start-follow-up-change
    }
}

# Update all or selected flake inputs in an isolated, checked JJ change.
def "main update" [
    ...inputs: string
    --publish (-p)
    --merge (-m)
] {
    if (current-change "empty") != "true" {
        error make {
            msg: "The working-copy change is not empty; run this from a fresh jj change"
        }
    }

    sync-main

    let subject = if ($inputs | is-empty) {
        "Update flake inputs"
    } else {
        $"Update ($inputs | str join ', ') flake inputs"
    }

    run-command "creating the update change" {
        ^jj new main@origin -m $subject
    } | ignore

    if ($inputs | is-empty) {
        run-command "updating flake inputs" { ^nix flake update } | ignore
    } else {
        run-command "updating flake inputs" { ^nix flake update ...$inputs } | ignore
    }

    if (current-change "empty") == "true" {
        print "Flake inputs are already current."
        run-command "abandoning the empty update" { ^jj abandon @ } | ignore
        return
    }

    ensure-flake-change
    run-command "checking the flake" { ^nix flake check } | ignore

    ^jj show -r @ --stat

    if ($publish or $merge) {
        publish-change $merge
    } else {
        print "Review with `jj show`; publish with `jj-flake publish`."
    }
}

# Publish the current checked flake update as a pull request.
def "main publish" [--merge (-m)] {
    publish-change $merge
}

# Fetch origin and align the local main bookmark with main@origin.
def "main sync" [] {
    sync-main
}

def main [] {
    print "Use `jj-flake update --help`, `jj-flake publish --help`, or `jj-flake sync`."
}
