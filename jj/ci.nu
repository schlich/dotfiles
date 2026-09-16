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

def save-publication-state [state: record] {
    $state | to json | save --force (publication-state-path)
}

def publication-topics [] {
    (publication-state) | get topics? | default {}
}

def slugify [title: string] {
    $title
    | str lowercase
    | str replace --all --regex "[^a-z0-9]+" "-"
    | str substring 0..47
    # Trim after truncation so a cut at a word boundary leaves no dash.
    | str trim --char "-"
}

def publication-slug [] {
    slugify (current-change "description.first_line()")
}

def legacy-publication-bookmark [bookmark: string] {
    let result = (^jj log -r $"($bookmark) & @" --no-graph -T 'commit_id' | complete)
    $result.exit_code == 0 and ($result.stdout | str trim | is-not-empty)
}

# Remembers the bookmark under the current topic's change id, so it survives
# title edits without leaking into whatever other topic next runs in this
# workspace (a single unscoped bookmark previously caused `publish` to reuse
# an already-merged topic's bookmark and PR).
def remember-publication-bookmark [bookmark: string] {
    let topics = (publication-topics) | upsert (current-topic-id) $bookmark
    save-publication-state { topics: $topics }
}

def forget-publication-bookmark [] {
    let topic_id = (current-topic-id)
    let topics = (publication-topics)
    if $topic_id in $topics {
        save-publication-state { topics: ($topics | reject $topic_id) }
    }
}

def publication-bookmark [] {
    let topic_id = (current-topic-id)
    let topics = (publication-topics)
    let remembered = if $topic_id in $topics {
        $topics | get $topic_id
    } else {
        # Migrate the pre-per-topic single-bookmark state, but only if it
        # still names the bookmark actually checked out right now — otherwise
        # a stale entry left by a different, already-finished topic would
        # leak onto whatever topic asks next.
        let legacy_single = (publication-state) | get bookmark? | default ""
        if ($legacy_single | is-not-empty) and (legacy-publication-bookmark $legacy_single) {
            $legacy_single
        } else {
            ""
        }
    }
    if ($remembered | is-not-empty) { return $remembered }

    let legacy = $"jj-($topic_id)"
    if (legacy-publication-bookmark $legacy) { return $legacy }

    new-publication-bookmark $topic_id (publication-slug)
}

def new-publication-bookmark [topic_id: string, slug: string] {
    let short_id = ($topic_id | str substring 0..7)
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
        ^jj rebase -s 'roots(main@origin..@)' -o main@origin --skip-emptied
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

# A stacked PR cannot use GitHub auto-merge while it targets its parent's
# branch: it would merge into that branch. This label records the request
# until `jj-ci refresh` sees the PR retargeted to main.
const AUTO_MERGE_LABEL = "jj-ci:auto-merge"

def bookmark-revset [bookmark: string] {
    $"bookmarks\(exact:'($bookmark)')"
}

# Move the commits of `tip` that are in neither `onto` nor main onto `onto`.
# Commits that become empty were already delivered (for example a squash-merged
# parent) and are dropped. Returns the revset of the restacked topic.
def restack [tip: string, onto: string] {
    if (revset-change-ids $"($onto) & ~::($tip)" | is-not-empty) {
        run-command $"rebasing ($tip) onto ($onto)" {
            ^jj rebase -s $"roots\(::($tip) ~ ::($onto) ~ ::main@origin)" -o $onto --skip-emptied
        } | ignore
    }
    $"($onto)..($tip)"
}

def enable-auto-merge [pr: any, head: string] {
    run-command $"enabling auto-merge for ($pr)" {
        github pr merge $pr --auto --squash --delete-branch --match-head-commit $head
    } | ignore
}

def request-deferred-auto-merge [pr: string] {
    git-command "creating the deferred auto-merge label" {
        github label create $AUTO_MERGE_LABEL --force --color 0E8A16 --description "jj-ci enables auto-merge once this stacked PR targets main"
    } | ignore
    git-command "labelling the pull request" { github pr edit $pr --add-label $AUTO_MERGE_LABEL } | ignore
}

# Bring one published topic up to date with its base: main@origin, or its
# parent's bookmark for a stacked PR. Conflicts stay recorded in the local
# rewrite and block the push until someone resolves them.
def refresh-topic [pr: record, push: bool] {
    let bookmark = $pr.headRefName
    let label = $"#($pr.number) ($bookmark)"
    let result = {|state| { pr: $pr.number branch: $bookmark state: $state } }
    if (revset-change-ids (bookmark-revset $bookmark) | is-empty) {
        return (do $result "no local bookmark")
    }
    let stacked = $pr.baseRefName != "main"
    let onto = if $stacked { bookmark-revset $pr.baseRefName } else { "main@origin" }
    if $stacked and (revset-change-ids $onto | is-empty) {
        print $"($label): parent branch ($pr.baseRefName) has no local bookmark."
        return (do $result "parent not local")
    }
    let checked_out = (revset-change-ids $"\(($onto)..($bookmark)):: & working_copies\()")
    if ($checked_out | is-not-empty) {
        print $"($label): checked out in a workspace at ($checked_out | str join ', '); run `jj-ci rebase` there."
        return (do $result "checked out")
    }
    let stack = (restack $bookmark $onto)
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"($label): ($conflicts | length) conflicted revision\(s), not pushed:"
        print-conflicted-files $conflicts "  "
        print "  Resolve oldest first: `jj new CHANGE_ID`, fix the files or run `jj resolve`, then `jj squash`."
        return (do $result "conflicted")
    }
    let head = (revision-id $bookmark)
    let changed = $head != $pr.headRefOid
    if not $push {
        if $changed { print $"($label): restacked cleanly to ($head | str substring 0..11); not pushed." }
        return (do $result (if $changed { "ready to push" } else { "current" }))
    }
    if $changed {
        push-topic-bookmark $bookmark
        print $"($label): pushed ($head | str substring 0..11)."
    }
    let armed = $pr.autoMergeRequest != null
    let deferred = ($pr.labels | any {|l| $l.name == $AUTO_MERGE_LABEL })
    if $stacked {
        if $armed {
            print $"($label): warning: auto-merge is enabled while the PR targets ($pr.baseRefName); it would merge into that branch."
        }
    } else if $armed and $changed {
        # Re-pin auto-merge to the rewritten head so it cannot merge anything else.
        enable-auto-merge $pr.number $head
    } else if $deferred and not $armed {
        enable-auto-merge $pr.number $head
        git-command "removing the deferred auto-merge label" {
            github pr edit $pr.number --remove-label $AUTO_MERGE_LABEL
        } | ignore
        print $"($label): now targets main; auto-merge enabled."
    }
    do $result (if $changed { "pushed" } else { "current" })
}

# Order PRs so every parent is refreshed before the PRs stacked on it.
def stack-order [prs: list] {
    mut ordered = []
    mut remaining = $prs
    mut bases = ["main"]
    loop {
        let known = $bases
        let ready = ($remaining | where {|pr| $pr.baseRefName in $known })
        if ($ready | is-empty) { break }
        $ordered = ($ordered | append $ready)
        $bases = ($bases | append ($ready | get headRefName))
        let taken = ($ready | get number)
        $remaining = ($remaining | where {|pr| $pr.number not-in $taken })
    }
    { ordered: $ordered unrooted: $remaining }
}

# Refresh PRs parent-first. A PR whose parent is conflicted or otherwise
# blocked waits, and so does everything stacked above it.
def refresh-outcomes [order: record, refresh: closure] {
    mut results = ($order.unrooted | each {|pr| { pr: $pr.number branch: $pr.headRefName state: "base is not main or an open PR" } })
    for pr in $order.ordered {
        let parent = ($results | where branch == $pr.baseRefName | get 0?)
        let blocked = $parent != null and $parent.state in ["conflicted" "parent not local" "waiting on parent"]
        let outcome = if $blocked {
            { pr: $pr.number branch: $pr.headRefName state: "waiting on parent" }
        } else {
            do $refresh $pr
        }
        $results = ($results | append $outcome)
    }
    $results
}

def refresh-topics [push: bool] {
    checkpoint "refresh"
    fetch-origin
    let prs = (git-command "listing open pull requests" {
        github pr list --state open --json number,headRefName,headRefOid,baseRefName,autoMergeRequest,labels
    } | from json)
    let results = (refresh-outcomes (stack-order $prs) {|pr| refresh-topic $pr $push })
    print ($results | table)
    if ($results | where state == "conflicted" | is-not-empty) {
        error make { msg: "Some topics have conflicts. Resolve them locally, then run `jj-ci refresh` again." }
    }
}

# Topics stacked beyond this depth wait for an earlier layer to land instead.
const PLAN_MAX_STACK = 3

def revision-field [revision: string, template: string] {
    let result = (^jj log -r $revision --no-graph -T $template | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | str trim
}

def contains-main [revision: string] {
    revset-change-ids $"main@origin & ::($revision)" | is-not-empty
}

# Create a headless merge of the given revisions, report whether it conflicts
# and whether it changes main, then abandon it. Working copies are untouched.
def trial-merge [revisions: list<string>] {
    let marker = $"jj-ci-plan-probe-(random uuid)"
    git-command "creating a trial merge" { ^jj new --no-edit -m $marker ...$revisions } | ignore
    let probe = (revision-field $"description\(substring:'($marker)')" 'commit_id')
    let conflict = (revision-field $probe 'conflict') == "true"
    let changes = (git-command "diffing the trial merge" {
        ^jj diff --name-only --from main@origin --to $probe
    } | is-not-empty)
    git-command "abandoning the trial merge" { ^jj abandon $probe } | ignore
    { conflict: $conflict changes: $changes }
}

def plan-topics [prs: list] {
    let published = ($prs | where {|pr| revset-change-ids (bookmark-revset $pr.headRefName) | is-not-empty })
    let roots = ($published | each {|pr| bookmark-revset $pr.headRefName } | append 'working_copies()' | str join ' | ')
    # A workspace parked on an empty, undescribed change contributes its parent.
    let placeholder = '(empty() & description(exact:""))'
    let tips = (revset-change-ids $"heads\(\(main@origin..\(($roots))) & mutable\() ~ ($placeholder))")
    $tips | each {|tip|
        let pr = ($published | where {|pr| revset-change-ids $"(bookmark-revset $pr.headRefName) & ::($tip)" | is-not-empty } | sort-by number | get 0?)
        let workspaces = (revision-field $"\(main@origin..($tip) | children\(($tip))) & working_copies\()" 'working_copies ++ " "'
            | split row " " | where {|name| $name | is-not-empty } | uniq)
        let names = (if $pr != null { [$"#($pr.number)"] } else { [] } | append $workspaces)
        let label = if ($names | is-empty) { $tip | str substring 0..7 } else { $names | str join " " }
        let fork = $"fork_point\(($tip) | main@origin)"
        {
            label: $label
            tip: $tip
            commit: (revision-id $tip)
            pr: ($pr | get number? )
            description: (revision-field $tip 'description.first_line()')
            timestamp: (revision-field $tip 'committer.timestamp().format("%s")' | into int)
            files: (git-command "listing topic files" { ^jj diff --name-only --from $fork --to $tip } | lines)
            current: (contains-main $tip)
        }
    }
}

def plan-main-status [topic: record] {
    let result = if $topic.current {
        {
            conflict: ((revision-field $topic.tip 'conflict') == "true")
            changes: (git-command "diffing the topic" { ^jj diff --name-only --from main@origin --to $topic.commit } | is-not-empty)
        }
    } else {
        trial-merge [main@origin $topic.commit]
    }
    if not $result.changes { "landed" } else if $result.conflict { "conflicts with main" } else { "clean" }
}

def plan-components [nodes: list<string>, edges: list] {
    mut seen = []
    mut components = []
    for node in $nodes {
        if $node in $seen { continue }
        mut component = [$node]
        mut frontier = [$node]
        while ($frontier | is-not-empty) {
            let current = ($frontier | first)
            $frontier = ($frontier | skip 1)
            let neighbours = ($edges
                | where {|edge| $edge.a == $current or $edge.b == $current }
                | each {|edge| if $edge.a == $current { $edge.b } else { $edge.a } }
                | where {|other| $other not-in $component })
            $component = ($component | append $neighbours)
            $frontier = ($frontier | append $neighbours)
        }
        $seen = ($seen | append $component)
        $components = ($components | append [$component])
    }
    $components
}

# Assign each conflict-free candidate a placement. Candidates arrive ordered
# published-first, so a chain never stacks a published topic on unpublished work.
def plan-proposals [candidates: list, edges: list] {
    plan-components ($candidates | get tip) $edges | each {|component|
        let chain = ($candidates | where tip in $component)
        $chain | enumerate | each {|entry|
            let action = if ($chain | length) == 1 {
                "independent"
            } else if $entry.index == 0 {
                "base"
            } else if $entry.index < $PLAN_MAX_STACK {
                "stack"
            } else {
                "hold"
            }
            let parent = if $action == "stack" { $chain | get ($entry.index - 1) } else { null }
            let proposal = match $action {
                "independent" => "independent PR"
                "base" => "base of stack"
                "stack" => $"stack on ($parent.label)"
                _ => $"hold until ($chain | get ($PLAN_MAX_STACK - 1) | get label) lands"
            }
            { tip: $entry.item.tip action: $action proposal: $proposal parent: $parent }
        }
    } | flatten
}

def build-plan [prs: list] {
    # Published topics go first so an open PR is never rebased onto unpublished work.
    let topics = (plan-topics $prs
        | each {|topic| $topic | insert main (plan-main-status $topic) }
        | insert unpublished {|topic| $topic.pr == null }
        | insert pr_order {|topic| $topic.pr | default 0 }
        | sort-by unpublished pr_order timestamp)
    let candidates = ($topics | where main == "clean")
    let pairs = ($candidates | enumerate | each {|left|
        $candidates | skip ($left.index + 1) | each {|right| { a: $left.item right: $right } }
    } | flatten)
    let edges = ($pairs
        | where {|pair| $pair.a.files | any {|file| $file in $pair.right.files } }
        | where {|pair|
            let revisions = if $pair.a.current or $pair.right.current {
                [$pair.a.commit $pair.right.commit]
            } else {
                [main@origin $pair.a.commit $pair.right.commit]
            }
            (trial-merge $revisions).conflict
        }
        | each {|pair| { a: $pair.a.tip b: $pair.right.tip } })
    let proposals = (plan-proposals $candidates $edges)
    $topics | each {|topic|
        let placement = match $topic.main {
            "landed" => { action: "landed" proposal: "already in main; finish or abandon" parent: null }
            "conflicts with main" => { action: "resolve-main" proposal: "resolve against main first (jj-ci rebase)" parent: null }
            _ => ($proposals | where tip == $topic.tip | get 0)
        }
        let conflicts = ($edges
            | where {|edge| $edge.a == $topic.tip or $edge.b == $topic.tip }
            | each {|edge| let other = if $edge.a == $topic.tip { $edge.b } else { $edge.a }; $topics | where tip == $other | get 0.label })
        {
            topic: $topic.label
            tip: $topic.tip
            change: ($topic.tip | str substring 0..7)
            description: $topic.description
            main: $topic.main
            conflicts_with: $conflicts
            action: $placement.action
            proposal: $placement.proposal
            stack_on_pr: ($placement.parent | get pr? )
            stack_on: ($placement.parent | get label? )
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
        "Checkmate formatting and unit-test skeleton"
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
    print "Use `jj-ci status`, `jj-ci sync`, `jj-ci plan`, `jj-ci rebase`, `jj-ci refresh`, `jj-ci conflicts`, `jj-ci review snapshot`, `jj-ci interdiff`, `jj-ci finish`, `jj-ci validate`, `jj-ci publish`, `jj-ci github reconcile`, `jj-ci stack-merge`, or `jj-ci tangled stack-publish`."
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

def "main plan" [
    --json # Print the plan as JSON
] {
    fetch-origin
    let prs = (git-command "listing open pull requests" {
        github pr list --state open --base main --json number,headRefName
    } | from json)
    let plan = (build-plan $prs)
    if $json {
        print ($plan | to json)
        return
    }
    if ($plan | is-empty) {
        print "No in-flight topics."
        return
    }
    for entry in $plan {
        let description = if ($entry.description | is-empty) { "(no description)" } else { $entry.description }
        print $"($entry.topic) [($entry.change)] ($description)"
        print $"  main: ($entry.main)"
        if ($entry.conflicts_with | is-not-empty) {
            print $"  conflicts with: ($entry.conflicts_with | str join ', ')"
        }
        print $"  plan: ($entry.proposal)"
    }
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

# Choose the branch a new topic should stack on. A topic built on top of an
# open PR depends on it and stacks on the nearest such PR; otherwise
# `jj-ci plan` decides. Returns null when the topic can go straight to main.
def plan-parent-for-current-topic [branch: string] {
    let open = (git-command "listing open pull requests" {
        github pr list --state open --json number,headRefName,baseRefName
    } | from json)
    let below = ($open | where {|pr|
        $pr.headRefName != $branch and (revset-change-ids $"(bookmark-revset $pr.headRefName) & ::@- ~ ::main@origin" | is-not-empty)
    })
    if ($below | is-not-empty) {
        let heads = (revset-change-ids $"heads\(($below | each {|pr| bookmark-revset $pr.headRefName } | str join ' | '))")
        let nearest = ($below | where {|pr| (revset-change-ids (bookmark-revset $pr.headRefName) | first) in $heads } | first)
        print $"Built on #($nearest.number); stacking on ($nearest.headRefName)."
        return $nearest.headRefName
    }
    let prs = ($open | where baseRefName == "main")
    let tip = (current-change 'change_id.short()')
    let entry = (build-plan $prs | where tip == $tip | get 0?)
    if $entry == null { return null }
    match $entry.action {
        "hold" => {
            error make { msg: $"This topic conflicts with a stack that is already ($PLAN_MAX_STACK) layers deep \(($entry.proposal)). Hold it locally until a layer lands." }
        }
        "stack" => {
            if $entry.stack_on_pr == null {
                error make { msg: $"This topic conflicts with unpublished work in ($entry.stack_on). Publish that topic first or wait for it to land." }
            }
            let parent = ($prs | where number == $entry.stack_on_pr | get 0.headRefName)
            print $"Conflicts with ($entry.conflicts_with | str join ', '); stacking on #($entry.stack_on_pr) \(($parent))."
            $parent
        }
        _ => null
    }
}

def restack-topic [parent: string] {
    require-owned-change
    if (print-conflicts "Before restack") {
        error make { msg: "Resolve existing conflicts before restacking." }
    }
    let onto = (bookmark-revset $parent)
    if (revset-change-ids $onto | is-empty) {
        error make { msg: $"The parent branch ($parent) has no local bookmark. Fetch and track it first." }
    }
    checkpoint "restack"
    let stack = (restack "@" $onto)
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"Restacked onto ($parent) with ($conflicts | length) conflicted revision\(s):"
        print-conflicted-files $conflicts "  "
        error make { msg: "Resolve these conflicts locally, oldest first, then run `jj-ci publish` again." }
    }
}

def "main publish" [--auto-merge] {
    require-ready-change
    let branch = (publication-bookmark)
    fetch-origin
    let pr = (do { github pr view $branch --json url,state,baseRefName } | complete)
    let existing = if $pr.exit_code == 0 { $pr.stdout | from json } else { null }
    if $existing != null and $existing.state != "OPEN" {
        error make { msg: "This topic's PR is closed or merged. Finish it before starting new work." }
    }
    # An existing PR keeps its base; a new topic follows `jj-ci plan`.
    let parent = if $existing != null {
        if $existing.baseRefName == "main" { null } else { $existing.baseRefName }
    } else {
        plan-parent-for-current-topic $branch
    }
    if $parent == null { rebase-topic } else { restack-topic $parent }
    require-ready-change
    validate-change
    let title = (current-change "description.first_line()")
    let head = (current-change "commit_id")
    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    remember-publication-bookmark $branch
    push-topic-bookmark $branch
    let url = if $existing != null {
        $existing.url
    } else {
        run-command "creating the pull request" {
            github pr create --base ($parent | default "main") --head $branch --title $title --body $"## Summary\\n\\n- ($title)\\n\\n## Validation\\n\\n- `jj-ci validate`"
        }
    }
    print $url
    if $auto_merge {
        if $parent == null {
            enable-auto-merge $url $head
            # A formerly stacked PR may still carry the deferral label.
            do { github pr edit $url --remove-label $AUTO_MERGE_LABEL } | complete | ignore
        } else {
            request-deferred-auto-merge $url
            print $"Stacked on ($parent): auto-merge is deferred until this PR targets main; `jj-ci refresh` enables it then."
        }
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
    # An empty workspace is either unpublished, or its merged topic was dropped
    # when a stacked child restacked with --skip-emptied.
    let delivery = if $empty {
        let prs = (run-command "checking for a published empty topic" {
            github pr list --state all --head $branch --json state,mergeCommit,url
        } | from json)
        if ($prs | where state != "MERGED" | is-not-empty) {
            error make { msg: "This empty topic has an unmerged PR. Resolve its delivery or closure explicitly before releasing the workspace." }
        }
        if ($prs | is-empty) {
            { url: "Unpublished empty topic" merged: null }
        } else {
            { url: ($prs | first | get url) merged: ($prs | first | get mergeCommit.oid) }
        }
    } else {
        let pr = (run-command "checking topic delivery" {
            github pr view $branch --json state,headRefOid,mergeCommit,url
        } | from json)
        if $pr.state != "MERGED" or $pr.headRefOid != $head {
            error make { msg: "The current revision must be merged without subsequent local edits before finishing. Leave the task open." }
        }
        { url: $pr.url merged: $pr.mergeCommit.oid }
    }
    let url = $delivery.url
    checkpoint "finish"
    run-command "fetching main" { ^jj git fetch --remote origin } | ignore
    if $delivery.merged != null {
        let delivered = (run-command "verifying delivery to main" {
            ^jj log -r $"($delivery.merged) & ::main@origin" --no-graph -T commit_id
        })
        if ($delivered | is-empty) {
            error make { msg: "The merge is not on main@origin yet. Leave the task open and retry later." }
        }
    }
    forget-publication-bookmark
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
