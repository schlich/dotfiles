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

def require-ready-change [] {
    if (current-change "conflict") == "true" {
        error make { msg: "Resolve JJ conflicts before publishing." }
    }
    if (current-change "empty") == "true" {
        error make { msg: "The current JJ change is empty." }
    }
    if ((current-change "description.first_line()") | is-empty) {
        error make { msg: "Describe the current JJ change before publishing." }
    }
}

def sync-main [] {
    if (current-change "empty") != "true" {
        error make { msg: "Sync only from an empty JJ working-copy change." }
    }

    run-command "fetching origin" { ^jj git fetch --remote origin } | ignore
    run-command "updating the main bookmark" {
        ^jj bookmark set main -r main@origin --allow-backwards
    } | ignore
    run-command "rebasing the working copy" { ^jj rebase -r @ -o main@origin } | ignore
}

def validate-change [] {
    run-command "running Prek" { ^prek run --all-files } | ignore
}

def start-follow-up-change [] {
    run-command "starting a follow-up change" { ^jj new @ } | ignore
    print "Started a fresh follow-up change. Subsequent edits will not rewrite the published revision."
}

def github-reconcile [apply: bool] {
    let required_checks = [
        "build home manager (shell, editor, and desktop)"
        "build NixOS (shell and compositor)"
        "build niri compositor config"
        "build zellij shell config"
        "build whitespace"
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
        print "Dry run only. Re-run with `jj-trunk github reconcile --apply` to enable auto-merge, branch deletion, and main protection."
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
    print "Use `jj-trunk status`, `jj-trunk sync`, `jj-trunk validate`, `jj-trunk publish`, `jj-trunk github reconcile`, or `jj-trunk stack-merge`."
}

def "main status" [] {
    ^jj status
    ^gh pr list --state open --base main --json number,headRefName,mergeStateStatus,mergeable,url
}

def "main sync" [] {
    sync-main
}

def "main validate" [] {
    require-ready-change
    validate-change
}

def "main publish" [--auto-merge] {
    require-ready-change
    validate-change

    let title = (current-change "description.first_line()")
    let change_id = (current-change "change_id.short()")
    let branch = $"trunk/($change_id)"
    let head = (current-change "commit_id")

    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    run-command "pushing the publication bookmark" {
        ^jj git push --remote origin --bookmark $branch
    } | ignore

    let pr = (do { ^gh pr view $branch --json url --jq .url } | complete)
    let url = if $pr.exit_code == 0 {
        $pr.stdout | str trim
    } else {
        run-command "creating the pull request" {
            ^gh pr create --base main --head $branch --title $title --body "## Summary\n\n- $title\n\n## Validation\n\n- `prek run --all-files`"
        }
    }
    print $url

    if $auto_merge {
        run-command "enabling pull request auto-merge" {
            ^gh pr merge $url --auto --squash --delete-branch --match-head-commit $head
        } | ignore
    }

    start-follow-up-change
}

def "main github reconcile" [--apply] {
    github-reconcile $apply
}

def "main stack-merge" [target: string] {
    stack-merge $target
}
