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
    let result = (^jj log -r @ --no-graph -T $template | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def publication-bookmark [] {
    # Stable across edits and title changes; independent topics cannot collide.
    $"jj-(current-change 'change_id')"
}

def checkpoint [label: string] {
    let root = (run-command "locating the workspace" { ^jj root })
    let operation = (run-command "recording a recovery point" {
        ^jj op log -n 1 --no-graph -T 'self.id()'
    })
    let directory = ($root | path join ".jj" "jj-ci-checkpoints")
    mkdir $directory
    $operation | save --force ($directory | path join $"(date now | format date '%Y%m%dT%H%M%S%f')-($label)")
    print $"Recovery point: jj op restore ($operation)"
}

def session-owner [] {
    let root = (run-command "locating the workspace" { ^jj root })
    let path = ($root | path join ".jj" "codex-session.json")
    if ($path | path exists) { open $path } else { null }
}

def require-owned-change [] {
    let owner = (session-owner)
    if $owner != null and not ($owner.finished? | default false) {
        if $owner.change_id != (current-change "change_id") {
            error make { msg: "This workspace is on a different change from its active Codex task. Resolve ownership before continuing." }
        }
    }
}

def require-ready-change [] {
    require-owned-change
    if (current-change "conflict") == "true" {
        error make { msg: "Resolve JJ conflicts before publishing." }
    }
    if (current-change "empty") == "true" {
        error make { msg: "The current JJ change is empty." }
    }
    if ((current-change "description.first_line()") | is-empty) {
        print "Describing the current JJ change."
        run-command "describing the current JJ change" { ^jj-describe } | ignore

        if ((current-change "description.first_line()") | is-empty) {
            error make { msg: "jj-describe did not describe the current JJ change." }
        }
    }
}

def sync-main [] {
    let owner = (session-owner)
    if $owner != null and not ($owner.finished? | default false) {
        error make { msg: "An active Codex topic owns this workspace. Use `jj-ci rebase`, or finish the topic before syncing." }
    }
    if (current-change "empty") != "true" {
        error make { msg: "Sync needs an empty change. Use `jj-ci rebase` to update this topic in place." }
    }

    checkpoint "sync"
    run-command "fetching origin" { ^jj git fetch --remote origin } | ignore
    run-command "advancing the main bookmark" {
        ^jj bookmark move main --to main@origin
    } | ignore
    run-command "rebasing the working copy" { ^jj rebase -r @ -o main@origin } | ignore
}

def validate-change [] {
    run-command "fixing the current JJ change" { ^jj fix -s @ } | ignore
    run-command "running Prek" { ^prek run --all-files } | ignore
}

def github-reconcile [apply: bool] {
    let required_checks = [
        "build home manager (shell, editor, and desktop)"
        "build NixOS (shell and compositor)"
        "build niri compositor config"
        "build zellij shell config"
    ]
    let repository = (run-command "reading repository metadata" {
        ^gh repo view --json nameWithOwner --jq .nameWithOwner
    })
    let owner = ($repository | split row "/" | first)
    let name = ($repository | split row "/" | last)
    let state = (run-command "reading GitHub repository settings" {
        ^gh api $"repos/($repository)" --jq '{allow_auto_merge, delete_branch_on_merge}'
    })
    let rule = (run-command "reading main branch protection" {
        ^gh api graphql -f query='
          query($owner: String!, $name: String!) {
            repository(owner: $owner, name: $name) {
              branchProtectionRules(first: 100) {
                nodes {
                  id
                  pattern
                  requiresStatusChecks
                  requiresStrictStatusChecks
                  requiredStatusCheckContexts
                }
              }
            }
          }' -F $"owner=($owner)" -F $"name=($name)"
    })

    print $"Repository settings: ($state)"
    print $"Branch protection: ($rule)"
    if not $apply {
        print $"Required checks: ($required_checks | str join ', ')"
        print "Dry run only. Re-run with `jj-ci github reconcile --apply` to enable auto-merge, branch deletion, and main protection."
        return
    }

    run-command "enabling GitHub auto-merge" {
        ^gh repo edit $repository --enable-auto-merge --delete-branch-on-merge
    } | ignore
    let protection = {
        required_status_checks: {
            strict: true
            contexts: $required_checks
        }
        enforce_admins: true
        required_pull_request_reviews: null
        restrictions: null
        required_linear_history: true
        allow_force_pushes: false
        allow_deletions: false
        block_creations: false
        required_conversation_resolution: true
        lock_branch: false
        allow_fork_syncing: false
    }
    run-command "protecting main" {
        $protection | to json --raw | ^gh api --method PUT $"repos/($repository)/branches/main/protection" --input -
    } | ignore
    print "Auto-merge, branch deletion, and required main checks are configured. GitHub applies merge-queue policy when available; `gh stack merge --yes` submits compatible stacks to that queue."
}

def stack-merge [target: string] {
    run-command "reading stacked pull request state" { ^gh stack view --json } | ignore
    run-command "submitting the stack to GitHub" {
        ^gh stack merge $target --yes --squash
    } | ignore
}

# Inspect, validate, publish, and reconcile JJ changes with GitHub trunk policy.
def main [] {
    print "Use `jj-ci status`, `jj-ci sync`, `jj-ci rebase`, `jj-ci finish`, `jj-ci validate`, `jj-ci publish`, `jj-ci github reconcile`, or `jj-ci stack-merge`."
}

# Show the current JJ change and open pull requests targeting main.
def "main status" [] {
    ^jj status
    ^gh pr list --state open --base main --json number,headRefName,mergeStateStatus,mergeable,url
}

# Fetch origin, advance main, and align an empty working copy with main@origin.
def "main sync" [] {
    sync-main
}

# Check that the current change is publishable and run Prek validation.
def "main validate" [] {
    require-ready-change
    validate-change
}

# Validate and publish the current change as a pull request.
def "main publish" [--auto-merge] {
    require-ready-change
    validate-change

    let title = (current-change "description.first_line()")
    let branch = (publication-bookmark)
    let head = (current-change "commit_id")

    let pr = (do { ^gh pr view $branch --json url,state } | complete)
    if $pr.exit_code == 0 and (($pr.stdout | from json).state != "OPEN") {
        error make { msg: "This topic's PR is closed or merged. Finish it before starting new work." }
    }
    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    run-command "pushing the publication bookmark" {
        ^jj git push --remote origin --bookmark $branch
    } | ignore

    let url = if $pr.exit_code == 0 {
        let existing = ($pr.stdout | from json)
        if $existing.state != "OPEN" {
            error make { msg: "This topic's PR is already closed or merged. Finish the session and start a new topic." }
        }
        $existing.url
    } else {
        run-command "creating the pull request" {
            ^gh pr create --base main --head $branch --title $title --body $"## Summary\n\n- ($title)\n\n## Validation\n\n- `prek run --all-files`"
        }
    }
    print $url

    if $auto_merge {
        run-command "enabling pull request auto-merge" {
            ^gh pr merge $url --auto --squash --delete-branch --match-head-commit $head
        } | ignore
    }

    print "Published this topic in place. Further edits update the same JJ change and PR."
}

# Inspect or apply the repository's declared GitHub policy.
def "main github reconcile" [--apply] {
    github-reconcile $apply
}

# Submit a linked, fully green pull request stack for squash merging.
def "main stack-merge" [target: string] {
    stack-merge $target
}

# Fetch and rebase the current topic without creating another change.
def "main rebase" [] {
    require-owned-change
    checkpoint "rebase"
    run-command "fetching origin" { ^jj git fetch --remote origin } | ignore
    run-command "rebasing the topic" { ^jj rebase -r @ -o main@origin } | ignore
    if (current-change "conflict") == "true" {
        error make { msg: "Rebase recorded conflicts in this same change. Resolve them before publishing." }
    }
}

# Complete a merged topic. Call before archiving its Codex task.
def "main finish" [] {
    require-owned-change
    let change = (current-change "change_id")
    let head = (current-change "commit_id")
    let branch = (publication-bookmark)
    let empty = (current-change "empty") == "true"
    let url = if $empty {
        let prs = (run-command "checking for a published empty topic" {
            ^gh pr list --state all --head $branch --json number
        } | from json)
        if ($prs | is-not-empty) {
            error make { msg: "This empty topic has a published PR. Resolve its delivery or closure explicitly before releasing the workspace." }
        }
        "Unpublished empty topic"
    } else {
        let pr = (run-command "checking topic delivery" {
            ^gh pr view $branch --json state,headRefOid,mergeCommit,url
        } | from json)
        if $pr.state != "MERGED" or $pr.headRefOid != $head {
            error make { msg: "The current revision must be merged without subsequent local edits before finishing. Leave the task open." }
        }
        $pr.url
    }
    checkpoint "finish"
    run-command "fetching main" { ^jj git fetch --remote origin } | ignore
    if not $empty {
        let pr = (run-command "reading the merge commit" {
            ^gh pr view $branch --json mergeCommit
        } | from json)
        let merged = $pr.mergeCommit.oid
        let delivered = (run-command "verifying delivery to main" {
            ^jj log -r $"($merged) & ::main@origin" --no-graph -T commit_id
        })
        if ($delivered | is-empty) {
            error make { msg: "The merge is not on main@origin yet. Leave the task open and retry later." }
        }
    }
    run-command "advancing main" { ^jj bookmark move main --to main@origin } | ignore
    run-command "leaving a clean workspace on main" { ^jj new main@origin } | ignore
    let root = (run-command "locating the workspace" { ^jj root })
    let owner_path = ($root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) {
        let owner = (open $owner_path)
        if $owner.change_id == $change {
            $owner | upsert finished true | to json | save --force $owner_path
            let claim = ($root | path join ".jj" "codex-session-claim")
            if ($claim | path exists) { rm --recursive $claim }
        }
    }
    print $"Finished ($url). Workspace is on main; the Codex task can now be archived."
}
