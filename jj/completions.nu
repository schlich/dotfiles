# Nushell completions for jj-ci. Keep these signatures in step with the
# `main` subcommands in jj/ci.nu.

def "nu-complete jj-ci review-labels" [] {
    let root = (^jj root | complete)
    if $root.exit_code != 0 { return [] }
    let path = ($root.stdout | str trim | path join ".jj" "jj-ci-review-versions.json")
    if not ($path | path exists) { return [] }
    open $path | each {|version| { value: $version.label, description: $version.created_at? } }
}

def "nu-complete jj-ci open-prs" [] {
    let prs = (^gh pr list --state open --json number,title | complete)
    if $prs.exit_code != 0 { return [] }
    $prs.stdout | from json | each {|pr| { value: ($pr.number | into string), description: $pr.title } }
}

def "nu-complete jj-ci revisions" [] {
    let bookmarks = (^jj bookmark list --all-remotes --template 'name ++ if(remote, "@" ++ remote) ++ "\n"' | complete)
    if $bookmarks.exit_code != 0 { return [] }
    $bookmarks.stdout | lines | uniq
}

# Inspect, synchronize, validate, publish, and reconcile JJ changes
export extern "jj-ci" []

# Show the working copy and open pull requests against main
export extern "jj-ci status" []

# Fetch origin, advance main, and rebase the empty working copy onto it
export extern "jj-ci sync" []

# Report Git worktrees and how far they are from origin/main
export extern "jj-ci worktree-status" []

# Validate the current change
export extern "jj-ci validate" []

# Record the current change as a named review version
export extern "jj-ci review snapshot" [
    label: string # Name for this review version
]

# Show the diff between two recorded review versions
export extern "jj-ci interdiff" [
    old: string@"nu-complete jj-ci review-labels" # Earlier review version
    new: string@"nu-complete jj-ci review-labels" # Later review version
]

# Rebase the current topic onto main
export extern "jj-ci rebase" []

# Plan how open pull requests should be ordered or stacked
export extern "jj-ci plan" [
    --json # Print the plan as JSON
]

# Build the Home Manager generation of trunk plus open pull requests without activating it
export extern "jj-ci preview" [
    ...prs: int@"nu-complete jj-ci open-prs" # Pull requests to include (default: every open behavior or breaking PR)
    --all # Include refactor pull requests when no numbers are given
    --shell # Open Nushell with the preview's programs first on PATH
    --config # With --shell, also read configuration from the preview (read-only)
    --active # Compare against the active generation instead of trunk's
]

# Restack stacked, retargeted, or conflicting pull requests
export extern "jj-ci refresh" [
    --no-push # Rebase and report conflicts without pushing or touching PRs
    --all # Also rebase conflict-free PRs that are merely behind main
]

# List conflicted revisions and files in the current topic
export extern "jj-ci conflicts" []

# Create or update the pull request for the current change
export extern "jj-ci publish" [
    --auto-merge # Request GitHub auto-merge against the current head
]

# Check Impact trailers on the commits between two revisions
export extern "jj-ci impact check" [
    base: string@"nu-complete jj-ci revisions" # Base revision
    head: string@"nu-complete jj-ci revisions" # Head revision
]

# Tag a release for behavior or breaking changes since the last release
export extern "jj-ci release" [
    --dry-run # Report the release without tagging it
]

# Describe the current revision against release tags
export extern "jj-ci version" []

# Report or apply the declared GitHub repository policy
export extern "jj-ci github reconcile" [
    --apply # Apply the declared policy
]

# Rebase, validate, and submit a stacked pull request chain
export extern "jj-ci stack-merge" [
    target: string@"nu-complete jj-ci open-prs" # Stack or pull request to merge
]

# Publish the current stack to Tangled
export extern "jj-ci tangled stack-publish" []

# Verify the current head merged to main and leave a clean working copy
export extern "jj-ci finish" [
    --wait # Wait for GitHub to merge the current head before finishing
    --timeout: duration # How long --wait waits (default 2hr)
]

# List stale workspaces and checkpoints
export extern "jj-ci prune" [
    --apply # Forget and delete the listed workspaces and checkpoints
    --keep-days: int # Keep checkpoints newer than this (default 14)
]
