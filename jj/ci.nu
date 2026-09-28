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

# Tangled hosts main and every topic branch. `jj-ci land` is the only path to
# main: it fast-forwards main to a head the spindle has already passed.
const TRUNK_REMOTE = "tangled"
# GitHub mirrors main, and its Actions can gate a landing in the spindle's
# place with `jj-ci land --gate github`. Its rules accept only fast-forwards.
const GITHUB_REMOTE = "origin"
const GITHUB_REQUIRED_CHECKS = ["impact classification" "nix flake checks"]
const TANGLED_INDEX = "https://api.tangled.org"
const TANGLED_WEB = "https://tangled.org"
const IDENTITY_RESOLVER = "https://slingshot.microcosm.blue"

def xrpc [service: string, method: string, params: record] {
    let response = (http get --full --allow-errors $"($service)/xrpc/($method)?($params | url build-query)")
    let body = if ($response.body | describe) == "string" {
        try { $response.body | from json } catch { $response.body }
    } else { $response.body }
    if $response.status != 200 {
        error make { msg: $"($method) on ($service) failed with HTTP ($response.status): ($body | to json --raw)" }
    }
    $body
}

# The Tangled repository behind the trunk remote. Its URL names the owner's
# handle and the repository; the repository record carries the repo DID that
# the index and spindle APIs key on, and the spindle that runs its pipelines.
def tangled-repo [] {
    let remotes = (git-command "listing remotes" { ^jj git remote list } | lines | parse "{name} {url}")
    let url = ($remotes | where name == $TRUNK_REMOTE | get --optional 0.url)
    if $url == null { error make { msg: $"This repository has no ($TRUNK_REMOTE) remote." } }
    let location = ($url | parse --regex '^(?:[^@/]+@[^:]+:|https?://[^/]+/)(?P<owner>[^/]+)/(?P<name>[^/]+?)(?:\.git)?/?$' | get --optional 0)
    if $location == null { error make { msg: $"Cannot read an owner and repository from ($url)." } }
    let owner = ($location.owner | str trim --left --char "@")
    let did = if ($owner | str starts-with "did:") {
        $owner
    } else {
        (xrpc $IDENTITY_RESOLVER "com.atproto.identity.resolveHandle" { handle: $owner }).did
    }
    let record = (xrpc $TANGLED_INDEX "sh.tangled.repo.getRepo" { repo: $"at://($did)/sh.tangled.repo/($location.name)" })
    {
        did: $record.value.repoDid
        spindle: ($record.value.spindle? | default "")
        web: $"($TANGLED_WEB)/($owner)/($location.name)"
    }
}

# Open pull requests with the branch each one proposes.
def open-pulls [repo: record] {
    (xrpc $TANGLED_INDEX "sh.tangled.repo.listPulls" { subject: $repo.did status: "open" limit: 100 }).items
    | each {|item| { title: $item.value.title branch: ($item.value.source?.branch? | default "") uri: $item.uri } }
}

# The spindle's verdict on one commit: success once every workflow passed,
# failed as soon as one failed, timed out, or was cancelled, missing before any
# pipeline started, and running otherwise.
def pipeline-state [repo: record, commit: string] {
    if ($repo.spindle | is-empty) {
        error make { msg: "The Tangled repository has no spindle, so no pipeline can gate landing. Select one in its settings." }
    }
    # A spindle that has not recorded the push yet omits `pipelines`.
    let pipelines = ((xrpc $"https://($repo.spindle)" "sh.tangled.ci.queryPipelines" { repo: $repo.did commits: $commit }).pipelines? | default [])
    let pipeline = ($pipelines | where commit == $commit | get --optional 0)
    let workflows = if $pipeline == null { [] } else { $pipeline.workflows }
    let state = if ($workflows | is-empty) {
        "missing"
    } else if ($workflows | any {|workflow| $workflow.status in ["failed" "timeout" "cancelled"] }) {
        "failed"
    } else if ($workflows | all {|workflow| $workflow.status == "success" }) {
        "success"
    } else {
        "running"
    }
    { state: $state workflows: $workflows }
}

# The GitHub repository behind the mirror remote, as `owner/name`.
def github-repo [] {
    let remotes = (git-command "listing remotes" { ^jj git remote list } | lines | parse "{name} {url}")
    let url = ($remotes | where name == $GITHUB_REMOTE | get --optional 0.url)
    if $url == null { error make { msg: $"This repository has no ($GITHUB_REMOTE) remote." } }
    let location = ($url | parse --regex 'github\.com[:/](?P<owner>[^/]+)/(?P<name>[^/]+?)(?:\.git)?/?$' | get --optional 0)
    if $location == null { error make { msg: $"($url) is not a GitHub repository." } }
    $"($location.owner)/($location.name)"
}

# GitHub's verdict on one commit, in the spindle's shape: the newest run of
# each required check decides, and a check that has not reported is missing.
# A skipped run proves nothing, so it counts as not having reported.
def github-checks-state [repo: string, commit: string] {
    let runs = (git-command "reading GitHub check runs" {
        ^gh api --paginate $"repos/($repo)/commits/($commit)/check-runs?per_page=100" --jq '.check_runs[] | {name, status, conclusion, id}'
    } | lines | where {|line| $line | is-not-empty } | each {|line| $line | from json }
    | where {|run| $run.conclusion not-in ["skipped" "neutral"] })
    let workflows = ($GITHUB_REQUIRED_CHECKS | each {|name|
        let matching = ($runs | where name == $name)
        let run = if ($matching | is-empty) { null } else { $matching | sort-by id | last }
        let status = if $run == null {
            "missing"
        } else if $run.status != "completed" {
            $run.status
        } else if $run.conclusion == "success" {
            "success"
        } else {
            "failed"
        }
        { name: $name status: $status }
    })
    let state = if ($workflows | any {|workflow| $workflow.status == "failed" }) {
        "failed"
    } else if ($workflows | all {|workflow| $workflow.status == "success" }) {
        "success"
    } else if ($workflows | all {|workflow| $workflow.status == "missing" }) {
        "missing"
    } else {
        "running"
    }
    { state: $state workflows: $workflows }
}

# Build every flake check at `commit` on this machine with the command the
# spindle workflow runs, streaming the build log. Outputs already in the local
# store or a binary cache are skipped, so a topic that leaves the system
# closures alone builds only the cheap checks. nix-fast-build caps evaluation
# at workers times the per-worker size; this machine allows 8 GiB rather than
# the spindle guest's 6 GiB, because den-host-evaluation alone needs about
# 6 GiB once a flake input brings its own nixpkgs.
def local-checks-state [commit: string] {
    let error = (with-commit-trees { head: $commit } {|trees|
        let flake = $"path:($trees.head)"
        try {
            ^nix --accept-flake-config run --inputs-from $flake nixpkgs#nix-fast-build -- --no-nom --skip-cached --eval-workers 2 --eval-max-memory-size 4096 --flake $"($flake)#checks.x86_64-linux"
            null
        } catch {|err|
            $err.msg
        }
    })
    let status = if $error == null { "success" } else { "failed" }
    { state: $status workflows: [{ name: "flake checks" status: $status error: ($error | default "") }] }
}

# The check that gates a landing: the flake checks built on this machine, the
# repository's spindle, or GitHub Actions on the mirror.
def landing-gate [gate: string, repo: record] {
    match $gate {
        "local" => {
            {
                name: $"local flake checks on (sys host | get hostname)"
                probe: {|commit| local-checks-state $commit }
                hint: ""
            }
        }
        "spindle" => {
            if ($repo.spindle | is-empty) {
                error make { msg: "The Tangled repository has no spindle, so no pipeline can gate landing. Select one in its settings." }
            }
            {
                name: $repo.spindle
                probe: {|commit| pipeline-state $repo $commit }
                hint: "If none started, check that .tangled/workflows runs on pushes to jj-* branches."
            }
        }
        "github" => {
            let github = (github-repo)
            {
                name: $"GitHub Actions on ($github)"
                probe: {|commit| github-checks-state $github $commit }
                hint: "If none started, check that .github/workflows/nix-ci.yml runs on pushes to jj-* branches."
            }
        }
        _ => { error make { msg: $"Unknown gate ($gate); use local, spindle, or github." } }
    }
}

# Poll the gate until it passes `commit`. Stop at the first failure; never
# rebase or push.
def wait-for-pipeline [gate: record, commit: string, timeout: duration] {
    let deadline = (date now) + $timeout
    mut last = ""
    loop {
        let pipeline = (do $gate.probe $commit)
        if $pipeline.state == "success" { return }
        if $pipeline.state == "failed" {
            let failed = ($pipeline.workflows | where status != "success" | each {|workflow|
                let detail = if ($workflow.error? | is-empty) { "" } else { $" \(($workflow.error | lines | last))" }
                $"($workflow.name): ($workflow.status)($detail)"
            })
            error make { msg: $"($gate.name) rejected ($commit | str substring 0..11): ($failed | str join '; '). Leave the task open." }
        }
        let status = if $pipeline.state == "missing" {
            $"waiting for ($gate.name) to start"
        } else {
            $"($pipeline.workflows | where status != 'success' | length) workflow\(s) running"
        }
        if $status != $last {
            print $"(date now | format date '%H:%M:%S') ($status)"
            $last = $status
        }
        if (date now) > $deadline {
            error make { msg: $"No passing pipeline for ($commit | str substring 0..11) after ($timeout). ($gate.hint)" }
        }
        sleep 30sec
    }
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

def forget-publication-bookmark [topic_id?: string] {
    let topic_id = ($topic_id | default (current-topic-id))
    let topics = (publication-topics)
    if $topic_id in $topics {
        save-publication-state { topics: ($topics | reject $topic_id) }
    }
}

def publication-bookmark [topic_id?: string] {
    let topic_id = ($topic_id | default (current-topic-id))
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
    push-bookmark $TRUNK_REMOTE $bookmark
}

def remote-bookmark-revset [bookmark: string, remote: string = $TRUNK_REMOTE] {
    $"remote_bookmarks\(exact:'($bookmark)', exact:'($remote)')"
}

# Delete a delivered topic's bookmark locally, on the trunk remote, and on the
# GitHub mirror if a GitHub-gated landing pushed it there.
def delete-topic-bookmark [bookmark: string] {
    if (revset-change-ids (bookmark-revset $bookmark) | is-not-empty) {
        run-command $"deleting ($bookmark)" { ^jj bookmark delete $bookmark } | ignore
    }
    for remote in [$TRUNK_REMOTE $GITHUB_REMOTE] {
        if (revset-change-ids (remote-bookmark-revset $bookmark $remote) | is-not-empty) {
            run-command $"deleting ($bookmark) from ($remote)" {
                ^jj git push --remote $remote --bookmark $bookmark
            } | ignore
        }
    }
}

# Whether the trunk remote's copy of a topic bookmark is already on main.
def topic-landed [bookmark: string] {
    revset-change-ids $"(remote-bookmark-revset $bookmark) & ::main@tangled" | is-not-empty
}

# Published topics: every local `jj-*` bookmark that is on the trunk remote and
# has work above main. A topic built on another one is stacked on the nearest
# such topic below it, so the graph alone records every stack.
def topic-bookmarks [] {
    let listing = (git-command "listing topic bookmarks" {
        ^jj bookmark list -T 'if(!remote && normal_target, name ++ "\t" ++ normal_target.commit_id() ++ "\n")' 'glob:jj-*'
    })
    let topics = ($listing | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { name: ($fields | first) commit: ($fields | last) }
    } | where {|topic|
        let pushed = (revset-change-ids (remote-bookmark-revset $topic.name) | is-not-empty)
        $pushed and (revset-change-ids $"main@tangled..(bookmark-revset $topic.name)" | is-not-empty)
    })
    $topics | each {|topic|
        let below = ($topics | where {|other|
            $other.commit != $topic.commit and (revset-change-ids $"(bookmark-revset $other.name) & ::(bookmark-revset $topic.name) ~ ::main@tangled" | is-not-empty)
        })
        let parent = if ($below | is-empty) {
            null
        } else {
            let heads = (revset-change-ids $"heads\(($below | each {|other| bookmark-revset $other.name } | str join ' | '))")
            $below | where {|other| (revset-change-ids (bookmark-revset $other.name) | first) in $heads } | first | get name
        }
        $topic | insert parent $parent
    }
}

def topic-revisions [] {
    let result = (^jj log -r 'main@tangled..@' --no-graph -T 'change_id ++ "\t" ++ commit_id ++ "\t" ++ description.first_line() ++ "\n"' | complete)
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
        error make { msg: "The current topic has no revisions above main@tangled." }
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

def require-owned-change [topic_id?: string] {
    let owner = (session-owner)
    if $owner != null and not ($owner.finished? | default false) {
        if $owner.change_id != ($topic_id | default (current-topic-id)) {
            error make { msg: "This workspace is on a different change from its active Codex task. Resolve ownership before continuing." }
        }
    }
    require-topic-checked-out
}

# Whether the working copy has wandered off the topic that `jj-ci start`
# recorded, as after a manual `jj new main`: it is an empty change the topic is
# not an ancestor of, while the topic still holds unlanded work. A topic that
# was abandoned, squashed away, or landed no longer counts, and a stack or a
# split keeps the topic below the working copy, so neither trips this.
def topic-stranded [facts: record] {
    $facts.recorded and $facts.visible and not $facts.landed and not $facts.ancestor and $facts.working_copy_empty and not $facts.topic_empty
}

def topic-facts [] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { error make { msg: ($root.stderr | str trim) } }
    let marker = (owned-workspace-marker ($root.stdout | str trim))
    let topic = if ($marker | path exists) { open $marker | get change_id? } else { null }
    if $topic == null {
        return { recorded: false visible: false landed: false ancestor: false working_copy_empty: false topic_empty: false topic: null }
    }
    let has = {|revset| revset-change-ids $"change_id\(($topic)\) & \(($revset)\)" | is-not-empty }
    {
        recorded: true
        visible: (do $has "all()")
        landed: (do $has "::main@tangled")
        ancestor: (do $has "::@")
        working_copy_empty: ((current-change "empty") == "true")
        topic_empty: (do $has "empty() & description(exact:\"\")")
        topic: $topic
    }
}

def require-topic-checked-out [] {
    let facts = (topic-facts)
    if not (topic-stranded $facts) { return }
    let short = ($facts.topic | str substring 0..7)
    let title = (revision-field $"change_id\(($facts.topic)\)" "description.first_line()")
    let stray = (current-change "change_id.short()")
    error make { msg: $"The working copy \(($stray)) has left this workspace's topic ($short) \"($title)\", as after `jj new main`. Return with `jj edit ($short)` and `jj abandon ($stray)`, or run `jj abandon ($short)` if the topic is meant to be dropped." }
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

def fetch-trunk [] {
    run-command $"fetching ($TRUNK_REMOTE)" { ^jj git fetch --remote $TRUNK_REMOTE } | ignore
}

def rebase-topic [] {
    require-owned-change
    if (print-conflicts "Before rebase") {
        error make { msg: "Resolve existing conflicts before rebasing onto main@tangled." }
    }
    checkpoint "rebase"
    fetch-trunk
    run-command "rebasing the topic stack" {
        ^jj rebase -s 'roots(main@tangled..@)' -o main@tangled --skip-emptied
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

# Every change declares its effect on the built machines with an `Impact:`
# trailer in its JJ description, ordered from least to most disruptive:
#   refactor  every NixOS closure is unchanged (refactors, docs, CI, tooling)
#   behavior  user-facing change; landing it cuts a CalVer release
#   breaking  user-facing change whose description body lists manual steps
const IMPACTS = ["refactor" "behavior" "breaking"]
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

# The impact of one topic from the impacts of its revisions. A topic lands as
# a unit, so a refactor must not share one with a user-facing change: it would
# lose its closure-neutral guarantee and ship inside a release. Returns
# { impact, problem } with exactly one non-null.
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
# Commits that become empty were already delivered and are dropped. Returns
# the revset of the restacked topic. With a workspace root, the rebase runs
# there so that working copy moves with it instead of going stale.
def restack [tip: string, onto: string, workspace?: string] {
    let repository = if $workspace == null { [] } else { [--repository $workspace] }
    if (revset-change-ids $"($onto) & ~::($tip)" | is-not-empty) {
        run-command $"rebasing ($tip) onto ($onto)" {
            ^jj ...$repository rebase -s $"roots\(::($tip) ~ ::($onto) ~ ::main@tangled)" -o $onto --skip-emptied
        } | ignore
    }
    $"($onto)..($tip)"
}

# Names of the workspaces whose working copy is in `revset`.
def workspaces-in [revset: string] {
    let result = (^jj log -r $"\(($revset)) & working_copies\()" --no-graph -T 'working_copies.map(|w| w.name()).join("\n") ++ "\n"' | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|name| $name | str trim | is-not-empty } | uniq
}

def workspace-root [name: string] {
    run-command $"locating workspace ($name)" { ^jj workspace root --name $name }
}

# Restack a topic that other workspaces have checked out. Each one is
# snapshotted first so no unrecorded edit is lost, the rebase runs only when a
# trial merge predicts no conflict, and the remaining workspaces are updated
# so none is left stale. Returns { stack } or, when the topic was left
# untouched, { reason }.
def restack-checked-out [bookmark: string, onto: string, workspaces: list<string>] {
    let roots = ($workspaces | each {|name| workspace-root $name })
    let unreachable = ($roots | where {|root| not ($root | path exists) })
    if ($unreachable | is-not-empty) {
        return { reason: $"cannot reach ($unreachable | str join ', ')" }
    }
    for root in $roots {
        run-command $"snapshotting ($root)" { ^jj --repository $root status } | ignore
    }
    if (conflicted-revisions $"($onto)..($bookmark)" | is-not-empty) {
        return { reason: "already conflicted" }
    }
    if (trial-merge [$onto (revision-id $bookmark)]).conflict {
        return { reason: "would conflict" }
    }
    let stack = (restack $bookmark $onto ($roots | first))
    for root in ($roots | skip 1) {
        run-command $"updating ($root)" { ^jj --repository $root workspace update-stale } | ignore
    }
    { stack: $stack }
}

# Whether a published topic needs rewriting. `jj-ci land` rebases a topic
# onto main itself, so rebasing one that merely fell behind only restarts its
# pipeline. A stacked topic must follow its parent, and a conflicting one
# cannot land at all.
def refresh-needed [topic: record, all: bool] {
    $all or $topic.parent != null or (trial-merge ["main@tangled" $topic.commit]).conflict
}

# Bring one published topic up to date with its base: main@tangled, or its
# parent's bookmark for a stacked topic. Conflicts stay recorded in the local
# rewrite and block the push until someone resolves them.
def refresh-topic [topic: record, push: bool, all: bool] {
    let bookmark = $topic.name
    let label = $bookmark
    let result = {|state| { branch: $bookmark state: $state } }
    if not (refresh-needed $topic $all) {
        return (do $result "no rebase needed")
    }
    let stacked = $topic.parent != null
    let onto = if $stacked { bookmark-revset $topic.parent } else { "main@tangled" }
    let workspaces = (workspaces-in $"\(($onto)..($bookmark))::")
    let restacked = if ($workspaces | is-empty) {
        { stack: (restack $bookmark $onto) }
    } else {
        restack-checked-out $bookmark $onto $workspaces
    }
    if $restacked.stack? == null {
        print $"($label): checked out in ($workspaces | str join ', ') and ($restacked.reason); left untouched for that workspace to resolve."
        return (do $result "checked out")
    }
    let stack = $restacked.stack
    let conflicts = (conflicted-revisions $stack)
    if ($conflicts | is-not-empty) {
        print $"($label): ($conflicts | length) conflicted revision\(s), not pushed:"
        print-conflicted-files $conflicts "  "
        print "  Resolve oldest first: `jj new CHANGE_ID`, fix the files or run `jj resolve`, then `jj squash`."
        return (do $result "conflicted")
    }
    let head = (revision-id $bookmark)
    let changed = $head != (revision-id (remote-bookmark-revset $bookmark))
    if not $push {
        if $changed { print $"($label): restacked cleanly to ($head | str substring 0..11); not pushed." }
        return (do $result (if $changed { "ready to push" } else { "current" }))
    }
    if $changed {
        push-topic-bookmark $bookmark
        print $"($label): pushed ($head | str substring 0..11)."
    }
    do $result (if $changed { "pushed" } else { "current" })
}

# Order topics so every parent is refreshed before the topics stacked on it.
def stack-order [topics: list] {
    mut ordered = []
    mut known = []
    mut remaining = $topics
    loop {
        let names = $known
        let ready = ($remaining | where {|topic| $topic.parent == null or $topic.parent in $names })
        if ($ready | is-empty) { break }
        $ordered = ($ordered | append $ready)
        $known = ($known | append ($ready | get name))
        let taken = ($ready | get name)
        $remaining = ($remaining | where {|topic| $topic.name not-in $taken })
    }
    $ordered
}

# Refresh topics parent-first. A topic whose parent is conflicted or otherwise
# blocked waits, and so does everything stacked above it.
def refresh-outcomes [ordered: list, refresh: closure] {
    mut results = []
    for topic in $ordered {
        let parent = ($results | where branch == $topic.parent | get --optional 0)
        let blocked = $parent != null and $parent.state in ["conflicted" "waiting on parent"]
        let outcome = if $blocked {
            { branch: $topic.name state: "waiting on parent" }
        } else {
            do $refresh $topic
        }
        $results = ($results | append $outcome)
    }
    $results
}

def refresh-topics [push: bool, all: bool] {
    checkpoint "refresh"
    fetch-trunk
    let results = (refresh-outcomes (stack-order (topic-bookmarks)) {|topic| refresh-topic $topic $push $all })
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
    revset-change-ids $"main@tangled & ::($revision)" | is-not-empty
}

# Create a headless merge of the given revisions, report whether it conflicts
# and whether it changes main, then abandon it. Working copies are untouched.
def trial-merge [revisions: list<string>] {
    let marker = $"jj-ci-plan-probe-(random uuid)"
    git-command "creating a trial merge" { ^jj new --no-edit -m $marker ...$revisions } | ignore
    let probe = (revision-field $"description\(substring:'($marker)')" 'commit_id')
    let conflict = (revision-field $probe 'conflict') == "true"
    let changes = (git-command "diffing the trial merge" {
        ^jj diff --name-only --from main@tangled --to $probe
    } | is-not-empty)
    git-command "abandoning the trial merge" { ^jj abandon $probe } | ignore
    { conflict: $conflict changes: $changes }
}

def plan-topics [published: list] {
    let roots = ($published | each {|topic| bookmark-revset $topic.name } | append 'working_copies()' | str join ' | ')
    # A workspace parked on an empty, undescribed change contributes its parent.
    let placeholder = '(empty() & description(exact:""))'
    let tips = (revset-change-ids $"heads\(\(main@tangled..\(($roots))) & mutable\() ~ ($placeholder))")
    $tips | each {|tip|
        let bookmark = ($published | where {|topic| revset-change-ids $"(bookmark-revset $topic.name) & ::($tip)" | is-not-empty } | sort-by name | get --optional 0.name)
        let workspaces = (revision-field $"\(main@tangled..($tip) | children\(($tip))) & working_copies\()" 'working_copies ++ " "'
            | split row " " | where {|name| $name | is-not-empty } | uniq)
        let names = (if $bookmark != null { [$bookmark] } else { [] } | append $workspaces)
        let label = if ($names | is-empty) { $tip | str substring 0..7 } else { $names | str join " " }
        let fork = $"fork_point\(($tip) | main@tangled)"
        {
            label: $label
            tip: $tip
            commit: (revision-id $tip)
            bookmark: $bookmark
            description: (revision-field $tip 'description.first_line()')
            # Author time survives rewrites; committer time moves whenever a
            # topic is validated or redescribed, which would reorder topics.
            created: (revision-field $"($fork)..($tip)" 'author.timestamp().format("%s") ++ "\n"'
                | lines | into int | math min)
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
            changes: (git-command "diffing the topic" { ^jj diff --name-only --from main@tangled --to $topic.commit } | is-not-empty)
        }
    } else {
        trial-merge [main@tangled $topic.commit]
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
                "independent" => "independent topic"
                "base" => "base of stack"
                "stack" => $"stack on ($parent.label)"
                _ => $"hold until ($chain | get ($PLAN_MAX_STACK - 1) | get label) lands"
            }
            { tip: $entry.item.tip action: $action proposal: $proposal parent: $parent }
        }
    } | flatten
}

# Published topics go first so a pushed branch is never rebased onto unpublished
# work. Within each group refactors come first, so a conflicting user-facing
# change stacks on the refactor and each release stays a small behavior diff.
# Every key is stable under rewrites, so concurrent topics agree on which of
# them is the base; the change ID breaks the remaining ties.
def plan-order [topics: list] {
    $topics
    | insert unpublished {|topic| $topic.bookmark == null }
    | insert impact_order {|topic| impact-order $topic.impact }
    | sort-by unpublished impact_order created tip
}

def build-plan [published: list] {
    let topics = (plan-topics $published
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
                [main@tangled $pair.a.commit $pair.right.commit]
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
            stack_on_bookmark: ($placement.parent | get bookmark? )
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
    fetch-trunk
    run-command "advancing the main bookmark" { ^jj bookmark move main --to main@tangled } | ignore
    run-command "rebasing the working copy" { ^jj rebase -r @ -o main@tangled } | ignore
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

def main [] {
    print "Use `jj-ci start`, `jj-ci status`, `jj-ci sync`, `jj-ci plan`, `jj-ci preview`, `jj-ci rebase`, `jj-ci refresh`, `jj-ci conflicts`, `jj-ci review snapshot`, `jj-ci interdiff`, `jj-ci validate`, `jj-ci publish`, `jj-ci land`, `jj-ci finish`, `jj-ci abandon`, `jj-ci prune`, `jj-ci tangled stack-publish`, `jj-ci impact check`, `jj-ci release`, or `jj-ci version`."
}

def "main status" [] {
    ^jj status
    let repo = (tangled-repo)
    let pulls = (open-pulls $repo)
    topic-bookmarks | each {|topic|
        {
            topic: $topic.name
            stacked_on: $topic.parent
            pipeline: (pipeline-state $repo $topic.commit).state
            pull: ($pulls | where branch == $topic.name | get --optional 0.title)
        }
    }
}

def "main sync" [] {
    sync-main
}

def "main worktree-status" [] {
    let root = (git-command "locating the Git repository" { ^git rev-parse --show-toplevel })
    let main = (git-command "locating tangled/main" { ^git -C $root rev-parse refs/remotes/tangled/main })
    let main_short = ($main | str substring 0..6)
    let listing = (git-command "listing Git worktrees" { ^git -C $root worktree list --porcelain })
    let worktrees = ($listing
        | split row "\n\n"
        | where {|entry| ($entry | str trim | is-not-empty) }
        | each {|entry|
            let path_line = ($entry | lines | where {|line| $line starts-with "worktree " } | first)
            git-worktree ($path_line | str substring 9..) $main
        })
    print $"tangled/main: ($main_short)"
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
        base: (revision-id "main@tangled")
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
    fetch-trunk
    let plan = (build-plan (topic-bookmarks | where parent == null))
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
            print $"  note: this refactor stacks on user-facing ($parent.topic) only because that topic is already published."
        }
    }
}

# Home Manager is embedded in this host; there is no standalone homeConfigurations output.
const PREVIEW_ATTRIBUTE = "nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage"

def preview-link [] {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "jj-ci" "preview-home"
}

# Published topics to preview: the requested ones, or every behavior or
# breaking topic (all of them with `all`). Refactors leave every closure
# unchanged, so they add merge risk without anything to try.
def preview-topics [names: list<string>, all: bool] {
    let topics = (topic-bookmarks | each {|topic|
        let revset = (bookmark-revset $topic.name)
        # A stacked topic is classified by its own layer; the merge still
        # includes its parent, since the parent is an ancestor of its head.
        let base = if $topic.parent == null { "main@tangled" } else { bookmark-revset $topic.parent }
        $topic
        | insert revset $revset
        | insert title (revision-field $revset 'description.first_line()')
        | insert impact (combine-impacts (revisions-in $"($base)..($revset)" | each {|revision| parse-impact $revision.description }) | get impact)
    })
    if ($names | is-not-empty) {
        let missing = ($names | where {|name| $name not-in ($topics | get name) })
        if ($missing | is-not-empty) {
            error make { msg: $"Not published topics: ($missing | str join ', ')" }
        }
        return ($topics | where name in $names)
    }
    if $all { return $topics }
    $topics | where impact in ["behavior" "breaking"]
}

# Configuration files that differ between two Home Manager generations. Each
# entry is a symlink into the store, so a changed target is a changed file;
# comparing targets also tolerates links whose destination no longer exists.
def preview-changed-files [current: string, preview: string] {
    let old = ($current | path join "home-files" | path expand)
    let new = ($preview | path join "home-files" | path expand)
    let result = (^diff --recursive --brief --no-dereference $old $new | complete)
    if $result.exit_code > 1 { error make { msg: $"comparing configuration files failed: ($result.stderr | str trim)" } }
    $result.stdout | lines | each {|line|
        let only = ($line | parse --regex '^Only in (?P<directory>.+): (?P<name>.+)$')
        if ($only | is-not-empty) {
            let entry = ($only | first)
            let status = if ($entry.directory | str starts-with $new) { "added" } else { "removed" }
            let path = ($entry.directory | str replace $new "" | str replace $old "" | path join $entry.name)
            { status: $status path: $"~($path)" }
        } else {
            let path = ($line | parse --regex $"($old | str replace --all '.' '\.')\(?P<path>/[^’'\\s]*\)" | get 0?.path | default "")
            { status: "changed" path: $"~($path)" }
        }
    }
}

# Build the Home Manager generation that trunk plus in-flight topics would
# produce, without activating it. The merge exists only in a temporary
# workspace and is abandoned afterwards; nothing is pushed or rewritten.
def "main preview" [
    ...topics: string # Topic branches to include (default: every published behavior or breaking topic)
    --all # Include refactor topics when no branches are given
    --shell # Open Nushell with the preview's programs first on PATH
    --config # With --shell, also read configuration from the preview (read-only)
    --active # Compare against the active generation instead of trunk's
] {
    fetch-trunk
    let included = (preview-topics $topics $all)
    if ($included | is-empty) {
        print "No published user-facing topics to preview."
        return
    }
    for topic in $included { print $"Including ($topic.name) ($topic.title)" }

    let heads = ($included | get revset | append "main@tangled" | str join " | ")
    let parents = (git-command "resolving topic heads" {
        ^jj log -r $"heads\(($heads))" --no-graph -T 'commit_id ++ "\n"'
    } | lines)
    let marker = $"jj-ci-preview-(random uuid)"
    git-command "creating the preview merge" { ^jj new --no-edit -m $marker ...$parents } | ignore
    let merge = (revision-field $"description\(substring:'($marker)')" 'commit_id')
    let discard = {|| git-command "abandoning the preview merge" { ^jj abandon $"($merge)::" } | ignore }

    if (revision-field $merge 'conflict') == "true" {
        let files = (git-command "listing conflicted files" { ^jj resolve --list -r $merge })
        do $discard
        print "The selected topics conflict when merged:"
        print ($files | lines | each {|line| $"  ($line)" } | str join "\n")
        error make { msg: "Preview a subset with `jj-ci preview BRANCH ...`, or see `jj-ci plan` for how to stack them." }
    }

    let name = ($marker | str substring 0..21)
    let directory = (mktemp --directory --tmpdir "jj-ci-preview.XXXXXX")
    let tree = ($directory | path join "tree")
    let link = (preview-link)
    mkdir ($link | path dirname)
    let built = (try {
        git-command "checking out the preview" { ^jj workspace add --revision $merge --name $name $tree } | ignore
        ^nix build --no-update-lock-file --out-link $link $"path:($tree)#($PREVIEW_ATTRIBUTE)"
        if not $active {
            git-command "checking out trunk" { ^jj --repository $tree new main@tangled } | ignore
            ^nix build --no-update-lock-file --out-link $"($link)-trunk" $"path:($tree)#($PREVIEW_ATTRIBUTE)"
        }
        null
    } catch {|error| $error.msg })
    do { ^jj workspace forget $name } | complete | ignore
    rm --recursive --force $directory
    do $discard
    if $built != null { error make { msg: $"Building the preview failed: ($built)" } }

    let preview = ($link | path expand)
    let baseline = if $active {
        { name: "the active generation" path: ($env.HOME | path join ".local" "state" "home-manager" "gcroots" "current-home") }
    } else {
        { name: "trunk" path: $"($link)-trunk" }
    }
    print $"\nPreview generation: ($preview)"
    if ($baseline.path | path expand) == $preview {
        print $"\nNo Home Manager changes against ($baseline.name)."
    } else if ($baseline.path | path exists) {
        print $"\nPackage changes against ($baseline.name):"
        ^nix store diff-closures $baseline.path $preview
        let files = (preview-changed-files ($baseline.path | path expand) $preview)
        print "\nConfiguration file changes:"
        print (if ($files | is-empty) { "  none" } else { $files | each {|file| $"  ($file.status | fill --width 8)($file.path)" } | str join "\n" })
    }
    if not $shell {
        print $"\nTry programs from ($preview | path join 'home-path' 'bin'), or re-run with --shell."
        return
    }
    let overrides = { PATH: ($env.PATH | prepend ($preview | path join "home-path" "bin")) JJ_CI_PREVIEW: $preview }
    let overrides = if $config {
        $overrides | insert XDG_CONFIG_HOME ($preview | path join "home-files" ".config")
    } else {
        $overrides
    }
    print "\nEntering the preview shell. Exit to return; nothing was activated."
    with-env $overrides { ^nu }
}

def "main refresh" [
    --no-push # Rebase and report conflicts without pushing
    --all # Also rebase conflict-free topics that are merely behind main
] {
    refresh-topics (not $no_push) $all
}

def "main conflicts" [] {
    require-owned-change
    if (print-conflicts "Conflict status") {
        error make { msg: "The current topic has unresolved conflicts." }
    }
}

# Choose the branch a topic should stack on. A topic built on top of another
# published topic depends on it and stacks on the nearest one; otherwise
# `jj-ci plan` decides. Returns null when the topic can go straight to main.
def plan-parent-for-current-topic [branch: string] {
    let published = (topic-bookmarks | where name != $branch)
    let below = ($published | where {|topic|
        revset-change-ids $"(bookmark-revset $topic.name) & ::@- ~ ::main@tangled" | is-not-empty
    })
    if ($below | is-not-empty) {
        let heads = (revset-change-ids $"heads\(($below | each {|topic| bookmark-revset $topic.name } | str join ' | '))")
        let nearest = ($below | where {|topic| (revset-change-ids (bookmark-revset $topic.name) | first) in $heads } | first)
        print $"Built on ($nearest.name); stacking on it."
        return $nearest.name
    }
    let tip = (current-change 'change_id.short()')
    let entry = (build-plan ($published | where parent == null) | where tip == $tip | get 0?)
    if $entry == null { return null }
    match $entry.action {
        "hold" => {
            error make { msg: $"This topic conflicts with a stack that is already ($PLAN_MAX_STACK) layers deep \(($entry.proposal)). Hold it locally until a layer lands." }
        }
        "stack" => {
            # Waiting on a topic that is not published can block indefinitely
            # when its task is idle. Publish independently; whichever lands
            # second resolves the conflict when it rebases.
            if $entry.stack_on_bookmark == null {
                print $"Conflicts with unpublished work in ($entry.stack_on); publishing as an independent topic. Whichever lands second resolves the conflict."
                return null
            }
            print $"Conflicts with ($entry.conflicts_with | str join ', '); stacking on ($entry.stack_on_bookmark)."
            $entry.stack_on_bookmark
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

# A process keeps the jj-ci on its PATH from launch, so an agent session that
# predates a rebuild, or a direnv shell from an older checkout, can publish
# with superseded logic (such as the old literal-`\n` PR body). The wrapper
# records the hash of the script it was built from; accept it only when it
# matches this workspace's jj/ci.nu or main@tangled's. Unwrapped runs and
# repositories without jj/ci.nu skip the check.
def require-current-jj-ci [] {
    let built = ($env.JJ_CI_SOURCE_SHA256? | default "")
    if ($built | is-empty) { return }
    let root = (^jj root | complete)
    if $root.exit_code != 0 { return }
    let local = ($root.stdout | str trim | path join "jj" "ci.nu")
    if not ($local | path exists) { return }
    if (open --raw $local | hash sha256) == $built { return }
    let trunk = (^jj file show -r main@tangled 'root:"jj/ci.nu"' | complete)
    if $trunk.exit_code == 0 and ($trunk.stdout | hash sha256) == $built { return }
    error make { msg: "This jj-ci was built from neither this workspace's jj/ci.nu nor main@tangled's. Rerun it as `direnv exec . jj-ci ...` in this workspace, or activate the configuration and start a new session." }
}

# Rebase or restack the current topic, validate it, and push its bookmark to
# the trunk remote. A topic keeps one bookmark for its whole life, so every
# publish updates the same branch and any pull request opened from it.
def publish-topic [] {
    require-current-jj-ci
    require-ready-change
    let branch = (publication-bookmark)
    fetch-trunk
    if (topic-landed $branch) {
        error make { msg: "This topic already landed on main. Finish it before starting new work." }
    }
    let parent = (plan-parent-for-current-topic $branch)
    let base = if $parent == null { "main@tangled" } else { bookmark-revset $parent }
    # Classify before rewriting anything so an unclassified topic fails fast.
    let impact = (require-impact (layer-revisions $base))
    if $parent == null { rebase-topic } else { restack-topic $parent }
    require-ready-change
    validate-change
    run-command "setting the publication bookmark" { ^jj bookmark set $branch -r @ } | ignore
    remember-publication-bookmark $branch
    push-topic-bookmark $branch
    { branch: $branch parent: $parent impact: $impact head: (current-change "commit_id") }
}

# Land a published topic. A declared refactor must leave every closure
# unchanged, and the gate must pass the exact head; main then fast-forwards
# to that commit, so main only ever holds tested trees. If main moved while the
# gate ran, landing would not be a fast-forward of what was tested, so this
# returns false without touching main and the caller starts over from the new
# main. Delivery is never a squash, rebase, or merge on a forge: both remotes
# receive the same commits.
def land-published [published: record, repo: record, timeout: duration, gate: string] {
    if $published.parent != null {
        error make { msg: $"This topic is stacked on ($published.parent). Land that topic first, then land this one." }
    }
    let checker = (landing-gate $gate $repo)
    let base = (revision-id "main@tangled")
    if $published.impact == "refactor" { require-closure-neutral $base $published.head }
    if $gate == "github" { push-bookmark $GITHUB_REMOTE $published.branch }
    print $"Waiting for ($checker.name) to pass ($published.head | str substring 0..11)."
    wait-for-pipeline $checker $published.head $timeout
    # Other workspaces share this repository and may have landed meanwhile.
    fetch-trunk
    if not (contains-main $published.head) { return false }
    run-command "advancing main" { ^jj bookmark set main -r $published.head } | ignore
    let pushed = (do { ^jj git push --remote $TRUNK_REMOTE --bookmark main } | complete)
    if $pushed.exit_code != 0 {
        # The lease lost a race with a landing after the fetch above. Put the
        # local bookmark back on the trunk so the retry starts from it.
        fetch-trunk
        if not (contains-main $published.head) {
            run-command "resetting main" { ^jj bookmark set main -r main@tangled --allow-backwards } | ignore
            return false
        }
        error make { msg: $"landing on ($TRUNK_REMOTE) failed with exit code ($pushed.exit_code): ($pushed.stderr | str trim)" }
    }
    mirror-main
    cut-releases $"($base)..($published.head)" false
    print $"Landed ($published.branch) on main. `jj-ci finish` releases the workspace."
    true
}

# Land a published topic, starting over when main moves under it. Each retry
# republishes (rebasing onto the new main and validating) and waits for the
# gate to pass the new head; a rebase conflict or a failing gate still stops.
def land-with-retries [published: record, repo: record, timeout: duration, gate: string, attempts: int] {
    if $attempts < 1 { error make { msg: "--attempts must be at least 1." } }
    mut current = $published
    for attempt in 1..$attempts {
        if (land-published $current $repo $timeout $gate) { return }
        if $attempt == $attempts { break }
        print $"main moved while the gate ran; rebasing onto the new main and trying again \(attempt ($attempt + 1) of ($attempts))."
        $current = (publish-topic)
    }
    error make { msg: $"main moved during each of ($attempts) landing attempts. Nothing landed; run `jj-ci land` again once main is quiet." }
}

# Fast-forward GitHub's main to the trunk's. Tangled is authoritative, so a
# rejected mirror push leaves the landing in place and reports how to retry.
def mirror-main [] {
    let fetched = (do { ^jj git fetch --remote $GITHUB_REMOTE --branch main } | complete)
    let pushed = if $fetched.exit_code == 0 {
        do { ^jj git push --remote $GITHUB_REMOTE --bookmark main } | complete
    } else { $fetched }
    if $pushed.exit_code != 0 {
        print --stderr $"Landed on ($TRUNK_REMOTE), but mirroring main to ($GITHUB_REMOTE) failed: ($pushed.stderr | str trim). Retry with `jj git push --remote ($GITHUB_REMOTE) --bookmark main`."
    }
}

def "main publish" [
    --land # Land the topic once the gate passes it
    --gate: string = "local" # What must pass the head before --land: local, spindle, or github
    --timeout: duration = 2hr # How long --land waits for the pipeline
    --attempts: int = 5 # How many times --land starts over when main moves
] {
    let published = (publish-topic)
    let repo = (tangled-repo)
    let pull = (open-pulls $repo | where branch == $published.branch | get --optional 0)
    if $pull == null {
        let form = ({ source: "branch" sourceBranch: $published.branch targetBranch: "main" } | url build-query)
        print $"Pushed ($published.branch). Open a pull request to review it on Tangled: ($repo.web)/pulls/new?($form)"
    } else {
        print $"Pushed ($published.branch), which updates the pull request \"($pull.title)\"."
    }
    if $published.parent != null {
        print $"Stacked on ($published.parent); it lands after that topic."
    }
    print $"Impact: ($published.impact)"
    if $land {
        land-with-retries $published $repo $timeout $gate $attempts
    } else {
        print "Published this topic in place. Further edits update the same JJ series and branch; `jj-ci land` delivers it."
    }
}

def "main land" [
    --gate: string = "local" # What must pass the head: local, spindle, or github
    --timeout: duration = 2hr # How long to wait for the pipeline
    --attempts: int = 5 # How many times to start over when main moves
] {
    let published = (publish-topic)
    land-with-retries $published (tangled-repo) $timeout $gate $attempts
}

# Export each revision in `revisions` (a record of name to commit) into its own
# temporary directory, run `body` with a record of name to path, and remove
# the directories again. An export holds exactly the commit's tree and no
# `.git`, so a check that reads its own source as a flake cannot follow a Git
# pointer out of the Nix store. In a JJ workspace the commits live in its Git
# backend, so Git is pointed there; a plain Git checkout needs nothing extra.
# Only the export sees that Git environment, not `body`.
def with-commit-trees [revisions: record, body: closure] {
    let backend = (try { ^jj git root | complete } catch { { exit_code: 1 stdout: "" } })
    let environment = if $backend.exit_code == 0 { { GIT_DIR: ($backend.stdout | str trim) } } else { {} }
    let root = (mktemp --directory --tmpdir "jj-ci-tree.XXXXXX")
    let trees = ($revisions | columns | reduce --fold {} {|name, trees| $trees | insert $name ($root | path join $name) })
    let outcome = try {
        with-env $environment {
            for name in ($revisions | columns) {
                let tree = ($trees | get $name)
                mkdir $tree
                let exported = (do { ^git archive --format=tar ($revisions | get $name) | ^tar -x -C $tree } | complete)
                if $exported.exit_code != 0 {
                    error make { msg: $"exporting ($name) failed: ($exported.stderr | str trim)" }
                }
            }
        }
        { value: (do $body $trees) error: null }
    } catch {|err|
        { value: null error: $err.msg }
    }
    rm --recursive --force $root
    if $outcome.error != null { error make { msg: $outcome.error } }
    $outcome.value
}

# Prove every NixOS closure at `head` matches `base`, or fail naming the hosts
# that changed.
def require-closure-neutral [base: string, head: string] {
    let differences = (with-commit-trees { base: $base head: $head } {|trees|
        closure-differences (closure-fingerprint $"path:($trees.base)") (closure-fingerprint $"path:($trees.head)")
    })
    if ($differences | is-not-empty) {
        error make { msg: $"Declared refactor, but these host closures changed: ($differences | str join ', '). Make the change closure-neutral or reclassify it as behavior or breaking." }
    }
    print "Every NixOS closure matches the base."
}

# Classify `base..head` from its commit trailers and, for a refactor, prove
# that every NixOS closure matches the merge base. Uses Git and Nix only, so it
# runs without a JJ workspace; `jj-ci land` runs the same proof itself.
def "main impact check" [base: string, head: string] {
    let log = (git-command "reading the topic commits" {
        ^git log --no-merges --format=%h%x1f%B%x1e $"($base)..($head)"
    })
    let revisions = ($log | split row "\u{1e}" | str trim | where {|entry| $entry | is-not-empty } | each {|entry|
        let fields = ($entry | split row "\u{1f}")
        { change_id: ($fields | first) description: ($fields | skip 1 | str join "\u{1f}") }
    })
    let impact = (require-impact $revisions)
    print $"Impact: ($impact)"
    if $impact != "refactor" { return }
    require-closure-neutral (git-command "finding the merge base" { ^git merge-base $base $head }) $head
}

const RELEASE_TAG_GLOB = "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].*"

# Tag a CalVer release on every user-facing revision in `range`, oldest first,
# and push each tag to the trunk remote. The tag names the release; the
# revision description, with its Impact trailer, is its notes.
def cut-releases [range: string, dry_run: bool] {
    let tags = (git-command "listing release tags" {
        ^jj tag list -T 'name ++ "\n"' $"glob:'($RELEASE_TAG_GLOB)'"
    } | lines | uniq)
    let revisions = (git-command "listing unreleased revisions" {
        ^jj log -r $range --reversed --no-graph -T 'commit_id ++ "\t" ++ committer.timestamp().utc().format("%Y.%m.%d") ++ "\t" ++ description.escape_json() ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { commit: ($fields | first) date: ($fields | get 1) description: ($fields | skip 2 | str join "\t" | from json) }
    })
    mut known = $tags
    for revision in $revisions {
        let impact = (parse-impact $revision.description)
        if $impact not-in ["behavior" "breaking"] { continue }
        let version = (next-version $revision.date $known)
        let title = $"($version): ($revision.description | lines | first)"
        if $dry_run {
            print $"would release ($title) at ($revision.commit | str substring 0..11)"
        } else {
            run-command $"tagging ($version)" { ^jj tag set $version -r $revision.commit } | ignore
            run-command $"pushing ($version) to ($TRUNK_REMOTE)" { ^jj git push --remote $TRUNK_REMOTE --tag $version } | ignore
            print $"released ($title)"
        }
        $known = ($known | append $version)
    }
}

# Release every user-facing revision on main since the newest release. `jj-ci
# land` releases what it lands; this catches up after a failed tag push.
# Without an earlier release, only main itself is considered.
def "main release" [--dry-run] {
    let newest = (^jj log -r $"latest\(tags\(glob:'($RELEASE_TAG_GLOB)') & ::main@tangled)" --no-graph -T commit_id | complete)
    let range = if $newest.exit_code == 0 and ($newest.stdout | str trim | is-not-empty) {
        $"($newest.stdout | str trim)..main@tangled"
    } else {
        "main@tangled"
    }
    cut-releases $range $dry_run
}

# The newest CalVer release contained in the current revision.
def "main version" [] {
    let commit = (current-change "commit_id")
    run-command "describing the current revision" {
        with-env (git-context) { ^git describe --tags --match $RELEASE_TAG_GLOB $commit }
    }
}

def "main tangled stack-publish" [] {
    require-ready-change
    rebase-topic
    require-ready-change
    validate-change
    push-tangled-stack
}

def list-workspaces [] {
    git-command "listing workspaces" {
        ^jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'
    } | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { name: ($fields | first) root: ($fields | last) }
    }
}

def current-workspace [] {
    let root = (run-command "locating the workspace" { ^jj root })
    list-workspaces | where root == $root | first
}

# `jj-ci start` writes this marker. A workspace that carries it belongs to its
# topic, and `finish` or `abandon` removes it when the topic ends.
def owned-workspace-marker [root: string] {
    $root | path join ".jj" "jj-ci-workspace.json"
}

# Forget a workspace and delete its directory. JJ abandons its empty working
# copy; the operation log keeps every other commit recoverable. The caller
# moves to the default checkout, since the dropped one may be its own.
def --env drop-workspace [workspace: record] {
    let default_root = (workspace-root "default")
    run-command $"forgetting ($workspace.name)" {
        ^jj --repository $default_root workspace forget $workspace.name
    } | ignore
    cd $default_root
    if ($workspace.root | path exists) { rm --recursive $workspace.root }
}

# Release the topic onto an empty change on main. A workspace that `jj-ci start`
# created is then dropped; any other one stays and its Codex owner is finished.
def --env release-workspace [summary: string, change: string, keep: bool] {
    let workspace = (current-workspace)
    run-command "leaving a clean workspace on main" { ^jj new main@tangled } | ignore
    if not $keep and $workspace.name != "default" and (owned-workspace-marker $workspace.root | path exists) {
        drop-workspace $workspace
        print $"($summary) Removed workspace ($workspace.name); continue from ($env.PWD)."
        return
    }
    let owner_path = ($workspace.root | path join ".jj" "codex-session.json")
    if ($owner_path | path exists) {
        let owner = (open $owner_path)
        if $owner.change_id == $change {
            $owner | upsert finished true | to json | save --force $owner_path
            let claim = ($workspace.root | path join ".jj" "codex-session-claim")
            if ($claim | path exists) { rm --recursive $claim }
        }
    }
    print $"($summary) Workspace is on main; the Codex task can now be archived."
}

def "main start" [
    name: string # Workspace and topic name
] {
    if $name !~ '^[a-z0-9][a-z0-9-]*$' {
        error make { msg: "Use a lowercase name of letters, digits, and hyphens." }
    }
    if $name in (list-workspaces | get name) {
        error make { msg: $"Workspace ($name) already exists. One topic owns one workspace; finish or abandon it first." }
    }
    let root = (workspace-root "default" | path join ".jj-workspaces" $name)
    if ($root | path exists) {
        error make { msg: $"($root) already exists. Inspect it with `jj-ci prune` before reusing the name." }
    }
    fetch-trunk
    run-command $"creating workspace ($name)" {
        ^jj --repository (workspace-root "default") workspace add --revision main@tangled --name $name $root
    } | ignore
    # The working-copy change JJ just created is the topic; recording it lets
    # later commands notice when the working copy leaves it.
    let topic = (^jj --repository $root log -r @ --no-graph -T change_id | complete)
    if $topic.exit_code != 0 { error make { msg: ($topic.stderr | str trim) } }
    { name: $name created: (date now | format date "%+") change_id: ($topic.stdout | str trim) } | to json | save (owned-workspace-marker $root)
    print $"Created ($root) on main@tangled. `jj-ci finish` or `jj-ci abandon` removes it when the topic ends."
}

# The topic that `finish` closes. Landing fast-forwards main onto the topic
# head, which makes the working-copy commit immutable, so jj parks the
# workspace on a new empty child. That child has no publication of its own;
# the landed parent it sits on is the topic.
def finish-topic-id [] {
    let current = (current-topic-id)
    if (current-change "empty") != "true" or (current-change "description") != "" {
        return $current
    }
    let parent = (^jj log -r "@- ~ root()" --no-graph -T 'change_id ++ "\n"' | complete)
    let parents = ($parent.stdout | lines | where {|line| $line | is-not-empty })
    if $parent.exit_code == 0 and ($parents | length) == 1 and ($parents | first) in (publication-topics) {
        $parents | first
    } else {
        $current
    }
}

def --env "main finish" [
    --keep # Keep a workspace that `jj-ci start` created
] {
    let change = (finish-topic-id)
    require-owned-change $change
    let branch = (publication-bookmark $change)
    let empty = (current-change "empty") == "true"
    checkpoint "finish"
    fetch-trunk
    # An empty working copy is either an unpublished topic or one parked on top
    # of its landed work; a published branch must be on main either way.
    let published = (revset-change-ids (remote-bookmark-revset $branch) | is-not-empty)
    if $empty {
        if $published and not (topic-landed $branch) {
            error make { msg: $"($branch) is published but not on main. Land or abandon it explicitly before releasing the workspace." }
        }
    } else if (revset-change-ids "@ & ::main@tangled" | is-empty) {
        error make { msg: "The current revision is not on main. Land it with `jj-ci land`, and leave the task open until it has." }
    }
    delete-topic-bookmark $branch
    forget-publication-bookmark $change
    run-command "advancing main" { ^jj bookmark move main --to main@tangled } | ignore
    let summary = if $published { $"Finished ($branch)." } else { "Finished an unpublished topic." }
    release-workspace $summary $change $keep
}

def --env "main abandon" [
    --keep # Keep a workspace that `jj-ci start` created
] {
    require-owned-change
    let change = (current-change "change_id")
    let branch = (publication-bookmark)
    let open = (open-pulls (tangled-repo) | where branch == $branch)
    if ($open | is-not-empty) {
        error make { msg: $"The pull request \"($open | first | get title)\" is still open. Close it deliberately before abandoning the topic." }
    }
    let revisions = (topic-revisions)
    checkpoint "abandon"
    forget-publication-bookmark
    delete-topic-bookmark $branch
    if ($revisions | is-not-empty) {
        run-command "abandoning the topic" { ^jj abandon ...($revisions | get change_id) } | ignore
    }
    release-workspace $"Abandoned ($revisions | length) revision\(s)." $change $keep
}

def owner-state [root: string] {
    let path = ($root | path join ".jj" "codex-session.json")
    if not ($path | path exists) { return "none" }
    if ((open $path).finished? | default false) { "finished" } else { "active" }
}

# The facts prune decides from. Running JJ inside a workspace snapshots any
# unrecorded edits first. A stale workspace is updated only when `refresh` is
# set, because updating rewrites its files.
def workspace-facts [workspace: record, current: string, refresh: bool] {
    let facts = {
        name: $workspace.name
        current: ($workspace.root == $current)
        exists: ($workspace.root | path exists)
        git_worktree: ($workspace.root | path join ".git" | path exists)
        codex_worktree: ($workspace.root | str starts-with ($env.CODEX_HOME? | default ($env.HOME | path join ".codex") | path join "worktrees"))
        owner: (owner-state $workspace.root)
        stale: false
        error: null
        pending: false
    }
    if $workspace.name == "default" or $facts.current or not $facts.exists or $facts.git_worktree or $facts.codex_worktree or $facts.owner == "active" {
        return $facts
    }
    let probe = {|| do { ^jj --repository $workspace.root log -r @ --no-graph -T commit_id } | complete }
    mut state = (do $probe)
    if $state.exit_code != 0 and ($state.stderr | str contains "stale") {
        if not $refresh { return ($facts | upsert stale true) }
        let updated = (do { ^jj --repository $workspace.root workspace update-stale } | complete)
        if $updated.exit_code != 0 { return ($facts | upsert error ($updated.stderr | str trim)) }
        $state = (do $probe)
    }
    if $state.exit_code != 0 { return ($facts | upsert error ($state.stderr | str trim | lines | first)) }
    # Everything above trunk except an empty, undescribed working copy. Landed
    # work is on main itself, so it never counts.
    let pending = (do {
        ^jj --repository $workspace.root log -r 'heads((main@tangled..@) ~ (@ & empty() & description(exact:"")))' --no-graph -T 'change_id ++ "\n"'
    } | complete)
    if $pending.exit_code != 0 { return ($facts | upsert error ($pending.stderr | str trim | lines | first)) }
    $facts | upsert pending ($pending.stdout | str trim | is-not-empty)
}

# Why prune must keep a workspace, or null when nothing in it is live: it is
# missing, or nothing above trunk remains except an empty undescribed working
# copy.
def prune-verdict [facts: record] {
    if $facts.name == "default" { return "default workspace" }
    if $facts.current { return "current workspace" }
    if not $facts.exists { return null }
    if $facts.git_worktree { return "Git worktree; remove it with its owner" }
    if $facts.codex_worktree { return "Codex worktree; archive its task instead" }
    if $facts.owner == "active" { return "owned by an active task" }
    if $facts.stale { return "stale; `jj-ci prune --apply` updates it and decides again" }
    if $facts.error != null { return $"unreadable: ($facts.error)" }
    if $facts.pending { return "has undelivered changes" }
    null
}

def prune-checkpoints [root: string, cutoff: datetime, apply: bool] {
    let directory = ($root | path join ".jj" "jj-ci-checkpoints")
    if not ($directory | path exists) { return 0 }
    let old = (ls $directory | where modified < $cutoff)
    if $apply { $old | each {|file| rm $file.name } | ignore }
    $old | length
}

# Prune is the backstop for owners that never released their workspace: a
# crashed task, or a workspace created before `jj-ci start`.
def --env "main prune" [
    --apply # Update stale workspaces, then forget and delete the listed ones and checkpoints
    --keep-days: int = 14 # Keep checkpoints newer than this
] {
    fetch-trunk
    let current = (git-command "locating the workspace" { ^jj root })
    if $apply { checkpoint "prune" }
    let reviewed = (list-workspaces | each {|workspace|
        let facts = (workspace-facts $workspace $current $apply)
        $workspace | insert keep (prune-verdict $facts)
    })
    let removable = ($reviewed | where keep == null)
    let kept = ($reviewed | where keep != null)
    let cutoff = (date now) - ($keep_days * 1day)
    for workspace in $removable {
        if $apply { drop-workspace $workspace }
        print $"(if $apply { 'removed' } else { 'would remove' }) ($workspace.name): ($workspace.root)"
    }
    for workspace in $kept {
        print $"kept ($workspace.name): ($workspace.keep)"
    }
    let checkpoints = ($kept | where {|workspace| $workspace.root | path exists } | each {|workspace| prune-checkpoints $workspace.root $cutoff $apply } | math sum)
    print $"(if $apply { 'Removed' } else { 'Would remove' }) ($checkpoints) checkpoint\(s) older than ($keep_days) days."
    if not $apply { print "Dry run only. Re-run with `jj-ci prune --apply` to remove them." }
}
