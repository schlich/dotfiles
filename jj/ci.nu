def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

def capture-command [label: string, command: closure] {
    let result = (do $command | complete)
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.stdout | str trim
}

def worktree-state [path: path, main: string] {
    let head = (capture-command "reading worktree HEAD" {
        ^git -C $path rev-parse --short HEAD
    })
    let branch_result = (^git -C $path symbolic-ref --short -q HEAD | complete)
    let branch = if $branch_result.exit_code == 0 {
        $branch_result.stdout | str trim
    } else {
        "detached"
    }
    let dirty = ((^git -C $path status --porcelain | complete).stdout | str trim | is-not-empty)
    let main_is_ancestor = (^git -C $path merge-base --is-ancestor $main HEAD | complete).exit_code == 0
    let head_is_ancestor = (^git -C $path merge-base --is-ancestor HEAD $main | complete).exit_code == 0
    let state = if $main_is_ancestor {
        "current"
    } else if $head_is_ancestor {
        "behind"
    } else {
        "diverged"
    }
    {
        path: ($path | path expand)
        branch: $branch
        head: $head
        state: $state
        dirty: $dirty
        jj_workspace: (($path | path join ".jj") | path exists)
    }
}

def current-change [template: string] {
    let result = (^jj log -r @ --no-graph -T $template | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def revision-id [revision: string] {
    let result = (^jj log -r $revision --no-graph -T 'commit_id' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def git-context [] {
    let root = (^jj root | complete)
    let backend = (^jj git root | complete)
    if $root.exit_code != 0 or $backend.exit_code != 0 {
        error make { msg: "Could not locate this JJ workspace and its Git backend." }
    }
    { GIT_DIR: ($backend.stdout | str trim) GIT_WORK_TREE: ($root.stdout | str trim) }
}

def --wrapped github [...args: string] {
    with-env (git-context) { ^gh ...$args }
}

def current-topic-id [] {
    current-change 'change_id'
}

def publication-bookmark [] {
    $"jj-(current-topic-id)"
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
        if $owner.change_id != (current-topic-id) {
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
    run-command "advancing the main bookmark" { ^jj bookmark move main --to main@origin } | ignore
    run-command "rebasing the working copy" { ^jj rebase -r @ -o main@origin } | ignore
}

def review-versions [] {
    let root = (run-command "locating the workspace" { ^jj root })
    let path = ($root | path join ".jj" "jj-ci-review-versions.json")
    if ($path | path exists) { open $path } else { [] }
}

def review-versions-path [] {
    let root = (run-command "locating the workspace" { ^jj root })
    $root | path join ".jj" "jj-ci-review-versions.json"
}

def validate-change [] {
    run-command "fixing the current JJ change" { ^jj fix -s @ } | ignore
    let context = (git-context)
    let files = (do {
        cd $context.GIT_WORK_TREE
        ^jj file list
    } | complete)
    if $files.exit_code != 0 { error make { msg: ($files.stderr | str trim) } }
    let paths = ($files.stdout | lines | where {|p| $p != "" })
    run-command "running Prek on JJ-tracked files" {
        with-env $context {
            cd $context.GIT_WORK_TREE
            ^prek run --files ...$paths
        }
    } | ignore
}

def github-reconcile [apply: bool] {
    let required_checks = [
        "build headless NixOS"
        "build NixOS (shell and compositor)"
        "build Home Manager modules (shell, editor, and desktop)"
        "build niri compositor config"
        "build zellij shell config"
        "whitespace"
    ]
    let repository = (run-command "reading repository metadata" {
        github repo view --json nameWithOwner --jq .nameWithOwner
    })
    let owner = ($repository | split row "/" | first)
    let name = ($repository | split row "/" | last)
    let state = (run-command "reading GitHub repository settings" {
        github api $"repos/($repository)" --jq '{allow_auto_merge, delete_branch_on_merge}'
    })
    let rule = (run-command "reading main branch protection" {
        github api graphql -f query='
          query(\$owner: String!, \$name: String!) {
            repository(owner: \$owner, name: \$name) {
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
        github repo edit $repository --enable-auto-merge --delete-branch-on-merge
    } | ignore
    let protection = {
        required_status_checks: { strict: true contexts: $required_checks }
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
        $protection | to json --raw | github api --method PUT $"repos/($repository)/branches/main/protection" --input -
    } | ignore
    print "Auto-merge, branch deletion, and required main checks are configured."
}

def stack-merge [target: string] {
    run-command "reading stacked pull request state" { github stack view --json } | ignore
    run-command "submitting the stack to GitHub" {
        github stack merge $target --yes --squash
    } | ignore
}

def main [] {
    print "Use `jj-ci status`, `jj-ci sync`, `jj-ci worktree-status`, `jj-ci rebase`, `jj-ci review snapshot`, `jj-ci interdiff`, `jj-ci finish`, `jj-ci validate`, `jj-ci publish`, `jj-ci github reconcile`, or `jj-ci stack-merge`."
}

def "main status" [] {
    ^jj status
    github pr list --state open --base main --json number,headRefName,mergeStateStatus,mergeable,url
}

def "main sync" [] {
    sync-main
}

def "main worktree-status" [] {
    let root = (capture-command "locating the Git worktree" { ^git rev-parse --show-toplevel })
    let main_result = (^git -C $root rev-parse --verify refs/remotes/origin/main | complete)
    if $main_result.exit_code != 0 {
        error make { msg: "origin/main is unavailable. Fetch origin before checking worktree freshness." }
    }
    let main = ($main_result.stdout | str trim)
    let main_short = (capture-command "abbreviating origin/main" { ^git -C $root rev-parse --short $main })
    let listing = (^git -C $root worktree list --porcelain | complete)
    if $listing.exit_code != 0 {
        error make { msg: ($listing.stderr | str trim) }
    }
    let paths = (
        $listing.stdout
        | lines
        | where {|line| $line | str starts-with "worktree " }
        | each {|line| $line | str replace "worktree " "" }
    )
    let rows = ($paths | each {|path| worktree-state $path $main })
    print $"origin/main: ($main_short)"
    for row in ($rows | sort-by state path) {
        let dirty = if $row.dirty { "dirty" } else { "clean" }
        let jj = if $row.jj_workspace { "jj" } else { "git" }
        let kind = $"($dirty), ($jj)"
        print $"($row.state) ($row.branch) ($row.head) ($kind) ($row.path)"
    }
}

def "main validate" [] {
    require-ready-change
    validate-change
}

def "main review snapshot" [label: string] {
    require-ready-change
    let versions = (review-versions)
    if (($versions | where label == $label | is-not-empty)) {
        error make { msg: $"A review snapshot named '($label)' already exists in this workspace." }
    }
    let entry = {
        label: $label
        base: (revision-id "main@origin")
        tip: (revision-id "@")
        bookmark: (publication-bookmark)
        created_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
    }
    (review-versions | append $entry | to json) | save --force (review-versions-path)
    print $"Saved review snapshot '($label)': ($entry.base)..($entry.tip)"
}

def "main interdiff" [old: string, new: string] {
    let versions = (review-versions)
    let old_matches = ($versions | where label == $old)
    let new_matches = ($versions | where label == $new)
    if ($old_matches | is-empty) {
        error make { msg: $"No review snapshot named '($old)' exists in this workspace." }
    }
    if ($new_matches | is-empty) {
        error make { msg: $"No review snapshot named '($new)' exists in this workspace." }
    }
    let old_version = ($old_matches | first)
    let new_version = ($new_matches | first)
    let old_range = $"($old_version.base)..($old_version.tip)"
    let new_range = $"($new_version.base)..($new_version.tip)"
    let context = (git-context)
    print $"Interdiff: ($old) -> ($new)"
    print $"  old: ($old_range)"
    print $"  new: ($new_range)"
    run-command "computing interdiff" {
        with-env $context {
            cd $context.GIT_WORK_TREE
            ^git range-diff $old_range $new_range
        }
    } | ignore
}

def "main rebase" [] {
    require-owned-change
    checkpoint "rebase"
    run-command "fetching origin" { ^jj git fetch --remote origin } | ignore
    run-command "rebasing the topic stack" {
        ^jj rebase -s 'roots(main@origin..@)' -o main@origin
    } | ignore
    if (current-change "conflict") == "true" {
        error make { msg: "Rebase recorded conflicts in this same change. Resolve them before publishing." }
    }
}

def "main publish" [--auto-merge] {
    require-ready-change
    validate-change
    let title = (current-change "description.first_line()")
    let branch = (publication-bookmark)
    let head = (current-change "commit_id")
    let pr = (do { github pr view $branch --json url,state } | complete)
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
            github pr create --base main --head $branch --title $title --body $"## Summary\\n\\n- ($title)\\n\\n## Validation\\n\\n- `jj-ci validate`"
        }
    }
    print $url
    if $auto_merge {
        run-command "enabling pull request auto-merge" {
            github pr merge $url --auto --squash --delete-branch --match-head-commit $head
        } | ignore
    }
    print "Published this topic in place. Further edits update the same JJ series and PR."
}

def "main github reconcile" [--apply] {
    github-reconcile $apply
}

def "main stack-merge" [target: string] {
    stack-merge $target
}

def "main finish" [] {
    require-owned-change
    let change = (current-change "change_id")
    let head = (current-change "commit_id")
    let branch = (publication-bookmark)
    let empty = (current-change "empty") == "true"
    let url = if $empty {
        let prs = (run-command "checking for a published empty topic" {
            github pr list --state all --head $branch --json number
        } | from json)
        if ($prs | is-not-empty) {
            error make { msg: "This empty topic has a published PR. Resolve its delivery or closure explicitly before releasing the workspace." }
        }
        "Unpublished empty topic"
    } else {
        let pr = (run-command "checking topic delivery" {
            github pr view $branch --json state,headRefOid,mergeCommit,url
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
            github pr view $branch --json mergeCommit
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
