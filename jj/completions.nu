# Nushell completions for ci. Keep these signatures in step with the
# `main` subcommands in jj/ci.nu.

def "nu-complete ci review-labels" [] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { return [] }
    let path = ($root.stdout | str trim | path join ".jj" "jj-ci-review-versions.json")
    if not ($path | path exists) { return [] }
    open $path | each {|version| { value: $version.label, description: $version.created_at? } }
}

def "nu-complete ci topics" [] {
    let topics = (^jj bookmark list --template 'if(!remote, name ++ "\t" ++ normal_target.description().first_line() ++ "\n")' 'glob:jj-*' | complete)
    if $topics.exit_code != 0 { return [] }
    $topics.stdout | lines | where {|line| $line | is-not-empty } | each {|line|
        let fields = ($line | split row "\t")
        { value: ($fields | first), description: ($fields | skip 1 | str join "\t") }
    }
}

def "nu-complete ci gates" [] {
    [
        { value: "local", description: "The flake checks built on this machine" }
        { value: "spindle", description: "The Tangled repository's spindle" }
        { value: "github", description: "GitHub Actions on the origin mirror" }
    ]
}

def "nu-complete ci revisions" [] {
    let bookmarks = (^jj bookmark list --all-remotes --template 'name ++ if(remote, "@" ++ remote) ++ "\n"' | complete)
    if $bookmarks.exit_code != 0 { return [] }
    $bookmarks.stdout | lines | uniq
}

# Inspect, synchronize, validate, publish, and reconcile JJ changes
export extern "ci" []

# Show the working copy and each published topic with its pipeline and pull request
export extern "ci status" []

# Print the current topic's published head, pipeline verdicts, and pull request as JSON
export extern "ci ci-state" []

# Fetch Tangled, advance main, and rebase the empty working copy onto it
export extern "ci sync" []

# Report Git worktrees and how far they are from tangled/main
export extern "ci worktree-status" []

# Validate the current change
export extern "ci validate" []

# Record the current change as a named review version
export extern "ci review snapshot" [
    label: string # Name for this review version
]

# Show the diff between two recorded review versions
export extern "ci interdiff" [
    old: string@"nu-complete ci review-labels" # Earlier review version
    new: string@"nu-complete ci review-labels" # Later review version
]

# Rebase the current topic onto main
export extern "ci rebase" []

# Plan how published topics should be ordered or stacked
export extern "ci plan" [
    --json # Print the plan as JSON
]

# Build the Home Manager generation of trunk plus published topics without activating it
export extern "ci preview" [
    ...topics: string@"nu-complete ci topics" # Topic branches to include (default: every published behavior or breaking topic)
    --all # Include refactor topics when no branches are given
    --shell # Open Nushell with the preview's programs first on PATH
    --config # With --shell, also read configuration from the preview (read-only)
    --active # Compare against the active generation instead of trunk's
]

# Restack stacked or conflicting published topics
export extern "ci refresh" [
    --no-push # Rebase and report conflicts without pushing
    --all # Also rebase conflict-free topics that are merely behind main
]

# List conflicted revisions and files in the current topic
export extern "ci conflicts" []

# Rebase, validate, and push the current topic to Tangled
export extern "ci publish" [
    --land # Land the topic once the gate passes it
    --gate: string@"nu-complete ci gates" # What must pass the head before --land (default local)
    --timeout: duration # How long --land waits for the pipeline (default 2hr)
    --attempts: int # How many times --land starts over when main moves (default 5)
]

# Publish the current topic, wait for its gate to pass it, and fast-forward main
export extern "ci land" [
    --gate: string@"nu-complete ci gates" # What must pass the head (default local)
    --timeout: duration # How long to wait for the pipeline (default 2hr)
    --attempts: int # How many times to start over when main moves (default 5)
]

# Check Impact trailers on the commits between two revisions
export extern "ci impact check" [
    base: string@"nu-complete ci revisions" # Base revision
    head: string@"nu-complete ci revisions" # Head revision
]

# Tag a release for behavior or breaking changes since the last release
export extern "ci release" [
    --dry-run # Report the release without tagging it
]

# Describe the current revision against release tags
export extern "ci version" []

# Publish the current stack to Tangled
export extern "ci tangled stack-publish" []

# Create a workspace at main@tangled for a concurrent actor's topic
export extern "ci start" [
    name: string # Workspace and topic name
]

# Start a topic as a new change on main@tangled in this workspace
export extern "ci new" [
    --message (-m): string # Description for the new topic
]

# Verify the current head landed on main and leave a clean working copy
export extern "ci finish" [
    --keep # Keep a workspace that `ci start` created
]

# Release a Codex task's claim that its task left behind, without touching the topic
export extern "ci unclaim" []

# List stale workspaces and checkpoints
export extern "ci prune" [
    --apply # Forget and delete the listed workspaces and checkpoints
    --keep-days: int # Keep checkpoints newer than this (default 14)
]
