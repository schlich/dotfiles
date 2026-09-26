def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if ($result.stdout | is-not-empty) { print --no-newline $result.stdout }
    if ($result.stderr | is-not-empty) { print --stderr --no-newline $result.stderr }
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code)" }
    }
    $result.stdout | str trim
}

def git-command [label: string, command: closure] {
    let result = (do $command | complete)
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed with exit code ($result.exit_code): ($result.stderr | str trim)" }
    }
    $result.stdout | str trim
}

def git-worktree [path: string, main: string] {
    let head = (git-command "reading worktree HEAD" { ^git -C $path rev-parse HEAD })
    let short_head = ($head | str substring 0..6)
    let branch_result = (^git -C $path symbolic-ref --short -q HEAD | complete)
    let branch = if $branch_result.exit_code == 0 and ($branch_result.stdout | str trim | is-not-empty) {
        $branch_result.stdout | str trim
    } else {
        "detached"
    }
    let dirty_result = (^git -C $path status --porcelain | complete)
    if $dirty_result.exit_code != 0 {
        error make { msg: $"Could not inspect worktree ($path): ($dirty_result.stderr | str trim)" }
    }
    let dirty = if ($dirty_result.stdout | str trim | is-empty) { "clean" } else { "dirty" }
    let main_in_head = (^git -C $path merge-base --is-ancestor $main HEAD | complete).exit_code == 0
    let head_in_main = (^git -C $path merge-base --is-ancestor HEAD $main | complete).exit_code == 0
    let state = if $head == $main {
        "current"
    } else if $main_in_head {
        "ahead"
    } else if $head_in_main {
        "behind"
    } else {
        "diverged"
    }
    let jj_result = (^jj --repository $path root | complete)
    let vcs = if $jj_result.exit_code == 0 { "jj" } else { "git" }
    {
        path: $path
        branch: $branch
        head: $short_head
        dirty: $dirty
        state: $state
        vcs: $vcs
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

def publication-state-path [] {
    let root = (run-command "locating the workspace" { ^jj root })
    $root | path join ".jj" "jj-ci-publication.json"
}

def publication-state [] {
    let path = (publication-state-path)
    if ($path | path exists) { open $path } else { {} }
}

def publication-slug [] {
    let title = (current-change "description.first_line()")
    $title
    | str lowercase
    | str replace --all --regex "[^a-z0-9]+" "-"
    | str trim --char "-"
    | str substring 0..47
}

def legacy-publication-bookmark [bookmark: string] {
    let result = (^jj log -r $"($bookmark) & @" --no-graph -T 'commit_id' | complete)
    $result.exit_code == 0 and ($result.stdout | str trim | is-not-empty)
}

def remember-publication-bookmark [bookmark: string] {
    { bookmark: $bookmark } | to json | save --force (publication-state-path)
}

def publication-bookmark [] {
    let state = (publication-state)
    let remembered = ($state | get bookmark? | default "")
    if ($remembered | is-not-empty) { return $remembered }

    let topic_id = (current-topic-id)
    let legacy = $"jj-($topic_id)"
    if (legacy-publication-bookmark $legacy) { return $legacy }

    let short_id = ($topic_id | str substring 0..7)
    let slug = (publication-slug)
    let label = if ($slug | is-empty) { "topic" } else { $slug }
    $"jj-($label)-($short_id)"
}

def push-bookmark [remote: string, bookmark: string] {
    # jj refuses to create a new bookmark on a remote it does not track.
    run-command $"tracking ($bookmark)@($remote)" {
        ^jj bookmark track $"($bookmark)@($remote)"
    } | ignore
    run-command $"pushing ($bookmark) to ($remote)" {
        ^jj git push --remote $remote --bookmark $bookmark
    } | ignore
}

def push-topic-bookmark [bookmark: string] {
    for remote in [origin tangled] {
        push-bookmark $remote $bookmark
    }
}

def topic-revisions [] {
    let result = (^jj log -r 'main@origin..@' --no-graph -T 'change_id ++ "\t" ++ commit_id ++ "\t" ++ description.first_line() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout
    | lines
    | where {|line| $line | str trim | is-not-empty }
    | reverse
    | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | get 0)
            commit_id: ($fields | get 1)
            description: ($fields | skip 2 | str join "\t")
        }
    }
}

def push-tangled-stack [] {
    let series = (current-topic-id)
    let revisions = (topic-revisions)
    if ($revisions | is-empty) {
        error make { msg: "The current topic has no revisions above main@origin." }
    }

    print $"Publishing ($revisions | length) Tangled stack layer(s) for series ($series):"
    for revision in $revisions {
        let branch = $"stack/($series)/($revision.change_id)"
        run-command $"pushing ($branch) to tangled" {
            ^jj git push --remote tangled --named $"($branch)=($revision.commit_id)"
        } | ignore
        print $"  ($branch): ($revision.description)"
    }
    print "Select `Submit as stacked PRs` in Tangled for these branches."
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

def conflicted-revisions [stack: string = "::@"] {
    let result = (^jj log -r $"conflicts\() & \(($stack)\)" --no-graph -T 'change_id ++ "\t" ++ description.first_line() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | str trim | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | first)
            description: ($fields | skip 1 | str join "\t")
        }
    }
}

def print-conflicted-files [revisions: list, indent: string] {
    for $revision in $revisions {
        print $"($indent)($revision.change_id) ($revision.description)"
        let files = (^jj resolve --list -r $revision.change_id | complete)
        if $files.exit_code == 0 {
            let paths = ($files.stdout | lines | where {|line| $line | str trim | is-not-empty })
            for $path in $paths { print $"($indent)  ($path)" }
        }
    }
}

def print-conflicts [context: string] {
    let revisions = (conflicted-revisions)
    if ($revisions | is-empty) {
        print $"($context): no conflicts in the current topic stack."
        return false
    }

    print $"($context): ($revisions | length) conflicted revision(s):"
    print-conflicted-files $revisions "  "
    print ""
    print $"Topic tip before selecting a revision: (current-topic-id)"
    print "Resolve each revision in order, then run `jj-ci conflicts` again."
    print "For a revision that is not @: run `jj edit CHANGE_ID`, edit or `jj resolve` its files, then return with `jj edit TOPIC_TIP`."
    print "Do not re-run `jj-ci rebase` until the current topic is conflict-free; the rebase already completed."
    true
}

def fetch-origin [] {
    run-command "fetching origin" { ^jj git fetch --remote origin } | ignore
}

def rebase-topic [] {
    require-owned-change
    if (print-conflicts "Before rebase") {
        error make { msg: "Resolve existing conflicts before rebasing onto main@origin." }
    }
    checkpoint "rebase"
    fetch-origin
    run-command "rebasing the topic stack" {
        ^jj rebase -s 'roots(main@origin..@)' -o main@origin
    } | ignore
    if (print-conflicts "Rebase completed") {
        error make { msg: "Rebase completed with conflicts. Resolve them before continuing." }
    }
}

def revset-change-ids [revset: string] {
    let result = (^jj log -r $revset --no-graph -T 'change_id.short() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | str trim | is-not-empty }
}

# Bring one published topic up to date with main@origin. Conflicts stay
# recorded in the local rewrite and block the push until someone resolves them.
def refresh-topic [pr: record, push: bool] {
    let bookmark = $pr.headRefName
    let label = $"#($pr.number) ($bookmark)"
    if (revset-change-ids $"bookmarks\(exact:'($bookmark)')" | is-empty) {
        return { pr: $pr.number state: "no local bookmark" }
    }
    let stack = $"main@origin..($bookmark)"
    let checked_out = (revset-change-ids $"\(($stack)):: & working_copies\()")
    if ($checked_out | is-not-empty) {
        print $"($label): checked out in a workspace at ($checked_out | str join ', '); run `jj-ci rebase` there."
        return { pr: $pr.number state: "checked out" }
    }
    if (revset-change-ids $"main@origin & ~::($bookmark)" | is-not-empty) {
        run-command $"rebasing ($bookmark) onto main@origin" {
            ^jj rebase -b $bookmark -o main@origin
        } | ignore
    }
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"($label): ($conflicts | length) conflicted revision\(s), not pushed:"
        print-conflicted-files $conflicts "  "
        print "  Resolve oldest first: `jj new CHANGE_ID`, fix the files or run `jj resolve`, then `jj squash`."
        return { pr: $pr.number state: "conflicted" }
    }
    let head = (revision-id $bookmark)
    if $head == $pr.headRefOid {
        return { pr: $pr.number state: "current" }
    }
    if not $push {
        print $"($label): rebased cleanly to ($head | str substring 0..11); not pushed."
        return { pr: $pr.number state: "ready to push" }
    }
    push-topic-bookmark $bookmark
    if $pr.autoMergeRequest != null {
        # Re-pin auto-merge to the rewritten head so it cannot merge anything else.
        run-command $"re-enabling auto-merge for #($pr.number)" {
            github pr merge $pr.number --auto --squash --delete-branch --match-head-commit $head
        } | ignore
    }
    print $"($label): pushed ($head | str substring 0..11)."
    { pr: $pr.number state: "pushed" }
}

def refresh-topics [push: bool] {
    checkpoint "refresh"
    fetch-origin
    let prs = (git-command "listing open pull requests" {
        github pr list --state open --base main --json number,headRefName,headRefOid,autoMergeRequest
    } | from json)
    let results = ($prs | each {|pr| refresh-topic $pr $push })
    print ($results | table)
    if ($results | where state == "conflicted" | is-not-empty) {
        error make { msg: "Some topics have conflicts. Resolve them locally, then run `jj-ci refresh` again." }
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
    fetch-origin
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
    print "Use `jj-ci status`, `jj-ci sync`, `jj-ci rebase`, `jj-ci refresh`, `jj-ci conflicts`, `jj-ci review snapshot`, `jj-ci interdiff`, `jj-ci finish`, `jj-ci validate`, `jj-ci publish`, `jj-ci github reconcile`, `jj-ci stack-merge`, or `jj-ci tangled stack-publish`."
}

def "main status" [] {
    ^jj status
    github pr list --state open --base main --json number,headRefName,mergeStateStatus,mergeable,url
}

def "main sync" [] {
    sync-main
}

def "main worktree-status" [] {
    let root = (git-command "locating the Git repository" { ^git rev-parse --show-toplevel })
    let main = (git-command "locating origin/main" { ^git -C $root rev-parse refs/remotes/origin/main })
    let main_short = ($main | str substring 0..6)
    let listing = (git-command "listing Git worktrees" { ^git -C $root worktree list --porcelain })
    let worktrees = ($listing
        | split row "\n\n"
        | where {|entry| ($entry | str trim | is-not-empty) }
        | each {|entry|
            let path_line = ($entry | lines | where {|line| $line starts-with "worktree " } | first)
            git-worktree ($path_line | str substring 9..) $main
        })
    print $"origin/main: ($main_short)"
    for worktree in $worktrees {
        let details = $"($worktree.dirty), ($worktree.vcs)"
        print $"($worktree.state) ($worktree.branch) ($worktree.head) ($details) ($worktree.path)"
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
    rebase-topic
}

def "main refresh" [
    --no-push # Rebase and report conflicts without pushing or touching PRs
] {
    refresh-topics (not $no_push)
}

def "main conflicts" [] {
    require-owned-change
    if (print-conflicts "Conflict status") {
        error make { msg: "The current topic has unresolved conflicts." }
    }
}

def "main publish" [--auto-merge] {
    require-ready-change
    rebase-topic
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
    remember-publication-bookmark $branch
    push-topic-bookmark $branch
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
    require-ready-change
    rebase-topic
    require-ready-change
    validate-change
    stack-merge $target
}

def "main tangled stack-publish" [] {
    require-ready-change
    rebase-topic
    require-ready-change
    validate-change
    push-tangled-stack
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
    push-bookmark tangled main
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
