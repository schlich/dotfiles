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

# Delete a delivered topic's bookmark locally and on both remotes. GitHub
# usually deleted its copy on merge, and the fetch then dropped the local one;
# the Tangled mirror still needs an explicit deletion.
def delete-topic-bookmark [bookmark: string] {
    if (revset-change-ids (bookmark-revset $bookmark) | is-not-empty) {
        run-command $"deleting ($bookmark)" { ^jj bookmark delete $bookmark } | ignore
    }
    for remote in [origin tangled] {
        if (revset-change-ids $"remote_bookmarks\(exact:'($bookmark)', exact:'($remote)')" | is-not-empty) {
            run-command $"deleting ($bookmark) from ($remote)" {
                ^jj git push --remote $remote --bookmark $bookmark
            } | ignore
        }
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

    print $"Publishing ($revisions | length) Tangled stack layer\(s) for series ($series):"
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

    print $"($context): ($revisions | length) conflicted revision\(s):"
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

# Every change declares its effect on the built machines with an `Impact:`
# trailer in its JJ description, ordered from least to most disruptive:
#   refactor  every NixOS closure is unchanged (refactors, docs, CI, tooling)
#   behavior  user-facing change; landing it cuts a CalVer release
#   breaking  user-facing change whose description body lists manual steps
const IMPACTS = ["refactor" "behavior" "breaking"]
const IMPACT_LABELS = {
    refactor: "Closure-neutral: no NixOS generation changes"
    behavior: "User-facing change: cuts a CalVer release"
    breaking: "User-facing change that needs manual steps"
}
const IMPACT_TRAILER = '^(?i)impact:\s*(?P<value>\S+)\s*$'

# The last `Impact:` trailer value in a description, lowercased, or "" when
# there is none. Not null: `each` drops null results, which would hide an
# unclassified revision from `combine-impacts`.
def parse-impact [description: string] {
    let values = ($description | lines | parse --regex $IMPACT_TRAILER | get value | str lowercase)
    if ($values | is-empty) { "" } else { $values | last }
}

# A description without its subject line and `Impact:` trailer.
def description-body [description: string] {
    $description
    | lines
    | skip 1
    | where {|line| $line | parse --regex $IMPACT_TRAILER | is-empty }
    | str join "\n"
    | str trim
}

# The impact of one PR from the impacts of its revisions. Squash merging turns
# a PR into one commit on main, so a refactor must not share a PR with a
# user-facing change: it would lose its closure-neutral guarantee and ship
# inside a release. Returns { impact, problem } with exactly one non-null.
def combine-impacts [impacts: list] {
    if ($impacts | is-empty) {
        return { impact: null problem: "The topic has no revisions to classify." }
    }
    let invalid = ($impacts | where {|impact| $impact not-in $IMPACTS })
    if ($invalid | is-not-empty) {
        return { impact: null problem: $"Every revision needs an `Impact: ($IMPACTS | str join '|')` trailer." }
    }
    let user_facing = ($impacts | where {|impact| $impact != "refactor" })
    if ($user_facing | is-empty) {
        { impact: "refactor" problem: null }
    } else if ($user_facing | length) != ($impacts | length) {
        { impact: null problem: "This topic mixes refactor and user-facing revisions. Publish the refactor as its own topic, or as the parent layer of a stack if the change depends on it." }
    } else if "breaking" in $user_facing {
        { impact: "breaking" problem: null }
    } else {
        { impact: "behavior" problem: null }
    }
}

# Sort key that lands refactors before user-facing changes.
def impact-order [impact: any] {
    if $impact == "refactor" { 0 } else { 1 }
}

# The next CalVer release for `date` (YYYY.MM.DD) given the existing tags.
def next-version [date: string, tags: list<string>] {
    let pattern = ('^' + ($date | str replace --all '.' '\.') + '\.(?P<serial>[0-9]+)$')
    let serials = ($tags | parse --regex $pattern | get serial | into int)
    let serial = if ($serials | is-empty) { 1 } else { ($serials | math max) + 1 }
    $"($date).($serial)"
}

# The PR body generated from the topic's revisions. The trailing trailer
# becomes part of the squash commit on main, where `jj-ci release` reads it.
def pull-request-body [revisions: list, impact: string] {
    let summary = ($revisions | each {|revision|
        let title = ($revision.description | lines | first)
        let body = (description-body $revision.description)
        if ($body | is-empty) or $impact == "breaking" {
            $"- ($title)"
        } else {
            $"- ($title)\n\n($body | lines | each {|line| if ($line | is-empty) { '' } else { $'  ($line)' } } | str join "\n")"
        }
    } | str join "\n")
    let meaning = match $impact {
        "refactor" => "No NixOS generation changes; CI verifies that every host closure is identical to the base. Landing it cuts no release."
        "behavior" => "Changes user-facing behavior. Landing it cuts a CalVer release (`YYYY.MM.DD.N`); activate it deliberately."
        _ => "Changes user-facing behavior and needs the manual steps below when activating. Landing it cuts a CalVer release."
    }
    let steps = if $impact == "breaking" {
        let text = ($revisions | each {|revision| description-body $revision.description } | where {|body| $body | is-not-empty } | str join "\n\n")
        $"\n## Manual steps\n\n($text)\n"
    } else { "" }
    $"## Summary\n\n($summary)\n\n## Impact\n\n**($impact)**: ($meaning)\n($steps)\n## Validation\n\n- `jj-ci validate`\n\nImpact: ($impact)"
}

# Revisions in `base..@`, oldest first, with full descriptions.
def layer-revisions [base: string] {
    revisions-in $"($base)..@"
}

def revisions-in [revset: string] {
    let result = (^jj log -r $revset --no-graph -T 'change_id.short() ++ "\t" ++ description.escape_json() ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout
    | lines
    | where {|line| $line | str trim | is-not-empty }
    | reverse
    | each {|line|
        let fields = ($line | split row "\t")
        { change_id: ($fields | first) description: ($fields | skip 1 | str join "\t" | from json) }
    }
}

def require-impact [revisions: list] {
    let missing = ($revisions | where {|revision| (parse-impact $revision.description) not-in $IMPACTS })
    for revision in $missing {
        print --stderr $"($revision.change_id): missing or invalid Impact trailer; add one with `jj describe -r ($revision.change_id)`."
    }
    let result = (combine-impacts ($revisions | each {|revision| parse-impact $revision.description }))
    if $result.problem != null { error make { msg: $result.problem } }
    let unexplained = ($revisions | where {|revision|
        (parse-impact $revision.description) == "breaking" and (description-body $revision.description | is-empty)
    })
    if ($unexplained | is-not-empty) {
        error make { msg: $"Describe the manual steps in the body of every breaking revision: ($unexplained | get change_id | str join ', ')." }
    }
    $result.impact
}

def ensure-impact-labels [] {
    for impact in $IMPACTS {
        git-command $"creating the impact:($impact) label" {
            github label create $"impact:($impact)" --force --color (if $impact == "refactor" { "C5DEF5" } else if $impact == "behavior" { "FBCA04" } else { "B60205" }) --description ($IMPACT_LABELS | get $impact)
        } | ignore
    }
}

def label-pull-request [pr: string, impact: string] {
    ensure-impact-labels
    let stale = ($IMPACTS | where {|other| $other != $impact } | each {|other| [--remove-label $"impact:($other)"] } | flatten)
    git-command "labelling the pull request impact" {
        github pr edit $pr --add-label $"impact:($impact)" ...$stale
    } | ignore
}

# Host name to toplevel derivation for every NixOS configuration in a flake.
def closure-fingerprint [flake: string] {
    git-command $"evaluating the NixOS closures of ($flake)" {
        ^nix eval --json --no-update-lock-file $"($flake)#nixosConfigurations" --apply 'configs: builtins.mapAttrs (_: c: builtins.unsafeDiscardStringContext c.config.system.build.toplevel.drvPath) configs'
    } | from json
}

# Hosts whose closure differs between two fingerprints, including added and
# removed hosts.
def closure-differences [base: record, head: record] {
    $base | columns | append ($head | columns) | uniq | sort | where {|host|
        ($base | get --optional $host) != ($head | get --optional $host)
    }
}

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
            impact: (combine-impacts (revisions-in $"($fork)..($tip)" | each {|revision| parse-impact $revision.description }) | get impact)
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

# Published topics go first so an open PR is never rebased onto unpublished
# work. Within each group refactors come first, so a conflicting user-facing
# change stacks on the refactor and each release stays a small behavior diff.
def plan-order [topics: list] {
    $topics
    | insert unpublished {|topic| $topic.pr == null }
    | insert impact_order {|topic| impact-order $topic.impact }
    | insert pr_order {|topic| $topic.pr | default 0 }
    | sort-by unpublished impact_order pr_order timestamp
}

def build-plan [prs: list] {
    let topics = (plan-topics $prs
        | each {|topic| $topic | insert main (plan-main-status $topic) }
        | plan-order $in)
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
            impact: $topic.impact
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
    # Path-aware jobs that can be skipped stay optional; these always report.
    let required_checks = [
        "build NixOS (shell and compositor)"
        "build Home Manager modules (shell, editor, and desktop)"
        "impact classification"
    ]
    let repository = (run-command "reading repository metadata" {
        github repo view --json nameWithOwner --jq .nameWithOwner
    })
    let owner = ($repository | split row "/" | first)
    let name = ($repository | split row "/" | last)
    let state = (run-command "reading GitHub repository settings" {
        github api $"repos/($repository)" --jq '{allow_auto_merge, delete_branch_on_merge, squash_merge_commit_title, squash_merge_commit_message}'
    })
    # A bare `-f query='...'` spanning lines does not parse as one argument.
    let query = '
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
      }'
    let rule = (run-command "reading main branch protection" {
        github api graphql -f $"query=($query)" -F $"owner=($owner)" -F $"name=($name)"
    })
    print $"Repository settings: ($state)"
    print $"Branch protection: ($rule)"
    if not $apply {
        print $"Required checks: ($required_checks | str join ', ')"
        print "Squash commits: PR_TITLE / PR_BODY, so the Impact trailer reaches main."
        print $"Labels: ($IMPACTS | each {|impact| $'impact:($impact)' } | str join ', ')"
        print "Dry run only. Re-run with `jj-ci github reconcile --apply` to enable auto-merge, branch deletion, squash messages, impact labels, and main protection."
        return
    }
    run-command "enabling GitHub auto-merge" {
        github repo edit $repository --enable-auto-merge --delete-branch-on-merge
    } | ignore
    # `jj-ci release` reads the Impact trailer from the squash commit body.
    run-command "using PR titles and bodies for squash commits" {
        github api --method PATCH $"repos/($repository)" -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
    } | ignore
    ensure-impact-labels
    let protection = {
        required_status_checks: { strict: true contexts: $required_checks }
        enforce_admins: true
        # Changes reach main only through pull requests; no approval is needed.
        required_pull_request_reviews: {
            dismiss_stale_reviews: true
            require_code_owner_reviews: false
            require_last_push_approval: false
            required_approving_review_count: 0
        }
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
    print "Use `jj-ci status`, `jj-ci sync`, `jj-ci plan`, `jj-ci rebase`, `jj-ci refresh`, `jj-ci conflicts`, `jj-ci review snapshot`, `jj-ci interdiff`, `jj-ci finish`, `jj-ci prune`, `jj-ci validate`, `jj-ci publish`, `jj-ci github reconcile`, `jj-ci stack-merge`, `jj-ci tangled stack-publish`, `jj-ci impact check`, `jj-ci release`, or `jj-ci version`."
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
        print $"  impact: ($entry.impact | default 'unclassified')"
        print $"  main: ($entry.main)"
        if ($entry.conflicts_with | is-not-empty) {
            print $"  conflicts with: ($entry.conflicts_with | str join ', ')"
        }
        print $"  plan: ($entry.proposal)"
        let parent = ($plan | where topic == ($entry.stack_on | default "") | get 0?)
        if $entry.impact == "refactor" and $parent != null and $parent.impact != "refactor" {
            print $"  note: this refactor stacks on user-facing ($parent.topic) only because that PR is already published."
        }
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
    let base = if $parent == null { "main@origin" } else { bookmark-revset $parent }
    # Classify before rewriting anything so an unclassified topic fails fast.
    let impact = (require-impact (layer-revisions $base))
    if $parent == null { rebase-topic } else { restack-topic $parent }
    require-ready-change
    validate-change
    let title = (current-change "description.first_line()")
    let head = (current-change "commit_id")
    let body = (pull-request-body (layer-revisions $base) $impact)
    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    remember-publication-bookmark $branch
    push-topic-bookmark $branch
    let url = if $existing != null {
        # The body is generated from the JJ descriptions on every publish.
        git-command "updating the pull request body" { github pr edit $existing.url --body $body } | ignore
        $existing.url
    } else {
        run-command "creating the pull request" {
            github pr create --base ($parent | default "main") --head $branch --title $title --body $body
        }
    }
    label-pull-request $url $impact
    print $url
    print $"Impact: ($impact)"
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

# CI gate: classify `base..head` from its commit trailers and, for a refactor,
# prove that every NixOS closure matches the merge base. Uses Git and Nix only,
# so it runs in CI without a JJ workspace. Merge commits, such as those from
# GitHub's "Update branch", carry no trailer and vanish in the squash.
def "main impact check" [base: string, head: string] {
    let log = (git-command "reading the pull request commits" {
        ^git log --no-merges --format=%h%x1f%B%x1e $"($base)..($head)"
    })
    let revisions = ($log | split row "\u{1e}" | str trim | where {|entry| $entry | is-not-empty } | each {|entry|
        let fields = ($entry | split row "\u{1f}")
        { change_id: ($fields | first) description: ($fields | skip 1 | str join "\u{1f}") }
    })
    let impact = (require-impact $revisions)
    print $"Impact: ($impact)"
    if $impact != "refactor" { return }

    let fork = (git-command "finding the merge base" { ^git merge-base $base $head })
    let root = (mktemp --directory --tmpdir "jj-ci-impact.XXXXXX")
    let trees = { base: ($root | path join "base") head: ($root | path join "head") }
    let outcome = try {
        git-command "checking out the merge base" { ^git worktree add --detach $trees.base $fork } | ignore
        git-command "checking out the head" { ^git worktree add --detach $trees.head $head } | ignore
        let differences = (closure-differences (closure-fingerprint $"path:($trees.base)") (closure-fingerprint $"path:($trees.head)"))
        { differences: $differences error: null }
    } catch {|err|
        { differences: [] error: $err.msg }
    }
    for tree in [$trees.base $trees.head] {
        ^git worktree remove --force $tree | complete | ignore
    }
    rm --recursive --force $root
    if $outcome.error != null { error make { msg: $outcome.error } }
    if ($outcome.differences | is-not-empty) {
        error make { msg: $"Declared refactor, but these host closures changed: ($outcome.differences | str join ', '). Make the change closure-neutral or reclassify it as behavior or breaking." }
    }
    print "Every NixOS closure matches the merge base."
}

const RELEASE_TAG_GLOB = "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].*"

# Publish a CalVer GitHub release for every user-facing commit on main's
# first-parent history since the newest release, oldest first. Released
# commits are never revisited, so reruns and skipped workflow runs are safe.
def "main release" [--dry-run] {
    let tags = (git-command "listing release tags" { ^git tag --list $RELEASE_TAG_GLOB } | lines)
    let newest = (^git describe --tags --abbrev=0 --match $RELEASE_TAG_GLOB HEAD | complete)
    # Without an earlier release, only the current commit is considered.
    let range = if $newest.exit_code == 0 { $"($newest.stdout | str trim)..HEAD" } else { "HEAD^..HEAD" }
    let commits = (git-command "listing unreleased commits" { ^git rev-list --first-parent --reverse $range } | lines)
    mut known = $tags
    for commit in $commits {
        let message = (git-command "reading the commit message" { ^git log -1 --format=%B $commit })
        let impact = (parse-impact $message)
        if $impact not-in ["behavior" "breaking"] { continue }
        let date = (with-env { TZ: "UTC" } {
            git-command "reading the commit date" { ^git log -1 --date=format-local:%Y.%m.%d --format=%cd $commit }
        })
        let version = (next-version $date $known)
        let title = $"($version): ($message | lines | first)"
        let notes = $"**Impact:** ($impact)\n\n(description-body $message)"
        if $dry_run {
            print $"would release ($title) at ($commit | str substring 0..11)"
        } else {
            run-command $"publishing release ($version)" {
                ^gh release create $version --target $commit --title $title --notes $notes
            } | ignore
            print $"released ($title)"
        }
        $known = ($known | append $version)
    }
}

# The newest CalVer release contained in the current revision.
def "main version" [] {
    let commit = (current-change "commit_id")
    run-command "describing the current revision" {
        with-env (git-context) { ^git describe --tags --match $RELEASE_TAG_GLOB $commit }
    }
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

const FAILED_CHECKS = ["FAILURE" "CANCELLED" "TIMED_OUT" "ACTION_REQUIRED" "STARTUP_FAILURE" "ERROR"]

# Poll the topic's PR until GitHub merges the exact current head. Stop early
# whenever it can no longer merge unattended: closed, head moved, behind main,
# a failed check, or no auto-merge request. It never rebases or pushes.
def wait-for-merge [branch: string, head: string, timeout: duration] {
    let deadline = (date now) + $timeout
    mut last = ""
    loop {
        let pr = (git-command "checking topic delivery" {
            github pr view $branch --json state,headRefOid,baseRefName,mergeStateStatus,autoMergeRequest,statusCheckRollup
        } | from json)
        if $pr.state == "MERGED" { return }
        if $pr.state != "OPEN" {
            error make { msg: "This topic's PR was closed without merging." }
        }
        if $pr.headRefOid != $head {
            error make { msg: "The PR head differs from the current revision. Publish the current revision before waiting." }
        }
        if $pr.baseRefName != "main" {
            error make { msg: $"This PR is stacked on ($pr.baseRefName). Once that lands, run `jj-ci refresh`, then wait again." }
        }
        if $pr.autoMergeRequest == null {
            error make { msg: "Auto-merge is not enabled, so the PR will not merge on its own. Run `jj-ci publish --auto-merge` first." }
        }
        if $pr.mergeStateStatus == "BEHIND" {
            error make { msg: "main advanced and strict checks require an up-to-date head. Run `jj-ci publish --auto-merge` again." }
        }
        let checks = ($pr.statusCheckRollup | default [])
        # Check runs report `status`/`conclusion`; commit statuses report `state`.
        let failed = ($checks
            | where {|check| ($check.conclusion? | default ($check.state? | default "")) in $FAILED_CHECKS }
            | each {|check| $check.name? | default ($check.context? | default "unnamed") })
        if ($failed | is-not-empty) {
            error make { msg: $"Checks failed: ($failed | str join ', '). Leave the task open." }
        }
        let running = ($checks
            | where {|check| ($check.status? | default ($check.state? | default "")) not-in ["COMPLETED" "SUCCESS"] }
            | length)
        let status = if $running > 0 { $"($running) check\(s) running" } else { "waiting for GitHub to merge" }
        if $status != $last {
            print $"(date now | format date '%H:%M:%S') ($status)"
            $last = $status
        }
        if (date now) > $deadline {
            error make { msg: $"Not merged after ($timeout). Leave the task open and retry later." }
        }
        sleep 30sec
    }
}

def "main finish" [
    --wait # Wait for GitHub to merge the current head before finishing
    --timeout: duration = 2hr # How long --wait waits
] {
    require-owned-change
    let change = (current-change "change_id")
    let head = (current-change "commit_id")
    let branch = (publication-bookmark)
    let empty = (current-change "empty") == "true"
    if $wait and not $empty { wait-for-merge $branch $head $timeout }
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
    if $delivery.merged != null { delete-topic-bookmark $branch }
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

# Why a workspace must be kept, or null when it holds nothing: its working
# copy is an empty, undescribed change on trunk and no active task owns it.
def workspace-keep-reason [workspace: record] {
    if $workspace.name == "default" { return "default workspace" }
    if not ($workspace.root | path exists) { return null }
    if ($workspace.root | path join ".git" | path exists) { return "Git worktree; remove it with its owner" }
    let owner_path = ($workspace.root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) and not ((open $owner_path).finished? | default false) {
        return "owned by an active task"
    }
    # Running JJ inside the workspace snapshots any unrecorded edits first.
    let state = (do { ^jj --repository $workspace.root log -r '@' --no-graph -T 'empty ++ "\t" ++ description.escape_json() ++ "\t" ++ parents.map(|p| p.commit_id()).join(",")' } | complete)
    if $state.exit_code != 0 { return "stale or unreadable; run `jj workspace update-stale` there first" }
    let fields = ($state.stdout | str trim | split row "\t")
    if ($fields | get 0) != "true" { return "has changes" }
    if ($fields | get 1 | from json | str trim | is-not-empty) { return "has a description" }
    let parents = ($fields | get 2 | split row "," | each {|id| $"\(($id) ~ ::main@origin)" } | str join " | ")
    if (revset-change-ids $parents | is-not-empty) { return "built on unmerged work" }
    null
}

def prune-checkpoints [root: string, cutoff: datetime, apply: bool] {
    let directory = ($root | path join ".jj" "jj-ci-checkpoints")
    if not ($directory | path exists) { return 0 }
    let old = (ls $directory | where modified < $cutoff)
    if $apply { $old | each {|file| rm $file.name } | ignore }
    $old | length
}

def "main prune" [
    --apply # Forget and delete the listed workspaces and checkpoints
    --keep-days: int = 14 # Keep checkpoints newer than this
] {
    fetch-origin
    let current = (git-command "locating the workspace" { ^jj root })
    let workspaces = (git-command "listing workspaces" {
        ^jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { name: ($fields | first) root: ($fields | last) }
    })
    let reviewed = ($workspaces | each {|workspace|
        let reason = if $workspace.root == $current { "current workspace" } else { workspace-keep-reason $workspace }
        $workspace | insert keep $reason
    })
    let removable = ($reviewed | where keep == null)
    let kept = ($reviewed | where keep != null)
    let cutoff = (date now) - ($keep_days * 1day)
    if $apply and ($removable | is-not-empty) { checkpoint "prune" }
    for workspace in $removable {
        if $apply {
            run-command $"forgetting ($workspace.name)" { ^jj workspace forget $workspace.name } | ignore
            if ($workspace.root | path exists) { rm --recursive $workspace.root }
        }
        print $"(if $apply { 'removed' } else { 'would remove' }) ($workspace.name): ($workspace.root)"
    }
    for workspace in $kept {
        print $"kept ($workspace.name): ($workspace.keep)"
    }
    let checkpoints = ($kept | each {|workspace| prune-checkpoints $workspace.root $cutoff $apply } | math sum)
    print $"(if $apply { 'Removed' } else { 'Would remove' }) ($checkpoints) checkpoint\(s) older than ($keep_days) days."
    if not $apply { print "Dry run only. Re-run with `jj-ci prune --apply` to remove them." }
}
