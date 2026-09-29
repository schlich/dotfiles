# Property-based tests for the pure planning helpers in jj/ci.nu, derived from
# the invariants in jj/JjCi.tla. Run with:
#
#   nu --no-config-file -c "source tests/jj-ci-properties.nu"
#
# Sourcing through `-c` defines ci.nu's helpers without running its `main`.
# tests/pbt.nu holds the generators and the runner.

source pbt.nu
source ../jj/ci.nu
source ../jj/guard.nu

const BLOCKING = ["conflicted" "waiting on parent"]
const REFRESH_STATES = [
    "current" "pushed" "ready to push" "conflicted"
    "parent not local" "no local bookmark" "checked out"
]

# Published topics with unique names. Parents may be another topic, absent, or
# null for a root. Cycles and missing parents exercise unrooted topic handling.
def gen-topics [key: string] {
    let count = (pick $"($key)/count" 8)
    let names = (0..<$count | each {|i| $"b($i)" })
    let parents = ([null "gone"] ++ $names)
    shuffle $"($key)/order" (0..<$count | each {|i|
        {
            name: ($names | get $i)
            parent: (pick-from $"($key)/parent/($i)" $parents)
        }
    })
}

def gen-graph [key: string] {
    let count = (pick $"($key)/count" 9)
    let nodes = (0..<$count | each {|i| $"t($i)" })
    let pairs = ($nodes | enumerate | each {|a|
        $nodes | skip ($a.index + 1) | each {|b| { a: $a.item b: $b } }
    } | flatten)
    let edges = ($pairs | enumerate | where {|pair| (pick $"($key)/edge/($pair.index)" 4) == 0 } | get item)
    { nodes: $nodes edges: $edges }
}

# Topic names whose parent chain reaches a root, by fixpoint.
def rooted-names [topics: list] {
    mut rooted = []
    loop {
        let known = $rooted
        let next = ($topics
            | where {|topic| $topic.parent == null or $topic.parent in $known }
            | get name
            | where {|name| $name not-in $known })
        if ($next | is-empty) { break }
        $rooted = ($rooted ++ $next)
    }
    $rooted
}

def reachable [start: string, edges: list] {
    mut seen = [$start]
    loop {
        let known = $seen
        let next = ($edges
            | each {|edge| if $edge.a in $known { $edge.b } else if $edge.b in $known { $edge.a } else { null } }
            | compact
            | where {|node| $node not-in $known }
            | uniq)
        if ($next | is-empty) { break }
        $seen = ($seen ++ $next)
    }
    $seen | sort
}

def canonical-partition [components: list] {
    $components | each {|component| $component | sort } | sort-by {|component| $component | str join "," }
}

# Publication bookmarks: stable, branch-safe names for a topic.

for-all "slugify is branch-safe and bounded" {|key|
    let slug = (slugify (gen-title $key))
    assert ($slug =~ '^([a-z0-9]+(-[a-z0-9]+)*)?$') $"not branch-safe: '($slug)'"
    assert (($slug | str length) <= 48) $"too long: '($slug)'"
}

for-all "slugify is idempotent" {|key|
    let once = (slugify (gen-title $key))
    assert equal (slugify $once) $once
}

for-all "new bookmarks end with the topic's short change id" {|key|
    let id = (gen-change-id $"($key)/id")
    let bookmark = (new-publication-bookmark $id (slugify (gen-title $"($key)/title")))
    assert ($bookmark =~ '^jj-[a-z0-9]+(-[a-z0-9]+)*-[k-z]{8}$') $"malformed: ($bookmark)"
    assert ($bookmark | str ends-with $"-($id | str substring 0..7)")
}

for-all "distinct topics never share a new bookmark" {|key|
    let a = (gen-change-id $"($key)/a")
    let b = (gen-change-id $"($key)/b")
    if ($a | str substring 0..7) != ($b | str substring 0..7) {
        let left = (new-publication-bookmark $a (slugify (gen-title $"($key)/ta")))
        let right = (new-publication-bookmark $b (slugify (gen-title $"($key)/tb")))
        assert not equal $left $right
    }
}

# Stack ordering: parents are always refreshed before their children.

for-all "stack-order returns each rooted topic exactly once" {|key|
    let topics = (gen-topics $key)
    let names = (stack-order $topics | get name? | default [])
    assert equal ($names | sort) (rooted-names $topics | sort)
    assert equal ($names | uniq | length) ($names | length)
}

for-all "stack-order is topological" {|key|
    let order = (stack-order (gen-topics $key))
    $order | enumerate | each {|entry|
        let earlier = ($order | first $entry.index | get name? | default [])
        assert ($entry.item.parent == null or $entry.item.parent in $earlier) $"($entry.item.name) precedes its parent ($entry.item.parent)"
    } | ignore
}

for-all "stack-order excludes cycles and topics with missing parents" {|key|
    let topics = (gen-topics $key)
    let order = (stack-order $topics | get name? | default [])
    assert equal ($order | sort) (rooted-names $topics | sort)
}

for-all "stack-order ignores input order" {|key|
    let topics = (gen-topics $key)
    let left = (stack-order $topics | get name? | default [] | sort)
    let right = (stack-order (shuffle $"($key)/again" $topics) | get name? | default [] | sort)
    assert equal $left $right
}

# Refresh: a blocked parent blocks everything stacked above it (TLA: a
# conflicted topic is never published, delivered, or finished).

for-all "refresh never touches topics above a blocked parent" {|key|
    let topics = (gen-topics $key)
    let ordered = (stack-order $topics)
    let outcome = {|topic| pick-from $"($key)/state/($topic.name)" $REFRESH_STATES }
    let results = (refresh-outcomes $ordered {|topic|
        { branch: $topic.name state: (do $outcome $topic) }
    })
    assert equal ($results | get branch? | default [] | sort) ($ordered | get name? | default [] | sort)
    for result in $results {
        let topic = ($topics | where name == $result.branch | first)
        let parent = ($results | where branch == $topic.parent | get 0?)
        if $parent != null and $parent.state in $BLOCKING {
            assert equal $result.state "waiting on parent"
        } else {
            assert equal $result.state (do $outcome $topic)
        }
    }
}

# Planning: conflict components and their stacking proposals.

for-all "plan-components is the connectivity partition" {|key|
    let graph = (gen-graph $key)
    let components = (plan-components $graph.nodes $graph.edges)
    assert equal ($components | flatten | sort) ($graph.nodes | sort)
    for component in $components {
        for node in $component {
            assert equal ($component | sort) (reachable $node $graph.edges)
        }
    }
}

for-all "plan-components ignores edge order and direction" {|key|
    let graph = (gen-graph $key)
    let flipped = (shuffle $"($key)/edges" $graph.edges | each {|edge| { a: $edge.b b: $edge.a } })
    assert equal (canonical-partition (plan-components $graph.nodes $graph.edges)) (canonical-partition (plan-components (shuffle $"($key)/nodes" $graph.nodes) $flipped))
}

for-all "plan proposals respect the stack limit and publication order" {|key|
    let graph = (gen-graph $key)
    # build-plan orders candidates published-first before proposing.
    let candidates = ($graph.nodes | enumerate | each {|entry|
        let published = (pick $"($key)/published/($entry.index)" 2) == 0
        { tip: $entry.item label: $entry.item pr: (if $published { 200 + $entry.index } else { null }) }
    } | sort-by {|candidate| $candidate.pr == null })
    let proposals = (plan-proposals $candidates $graph.edges)
    assert equal ($proposals | get tip? | default [] | sort) ($graph.nodes | sort)
    for component in (plan-components ($candidates | get tip? | default []) $graph.edges) {
        let placed = ($proposals | where tip in $component)
        if ($component | length) == 1 {
            assert equal ($placed | get action) ["independent"]
        } else {
            assert equal ($placed | where action == "base" | length) 1
            assert (($placed | where action != "hold" | length) <= $PLAN_MAX_STACK)
            assert equal ($placed | where action == "hold" | length) ([0 (($component | length) - $PLAN_MAX_STACK)] | math max)
        }
        for proposal in ($placed | where action == "stack") {
            assert ($proposal.parent.tip in $component) "a stack parent must conflict with its child"
            let child = ($candidates | where tip == $proposal.tip | first)
            if $child.pr != null {
                assert ($proposal.parent.pr != null) $"published ($child.tip) stacks on unpublished ($proposal.parent.tip)"
            }
        }
    }
}

# Impact classes: trailers, PR classification, release numbering, and plan order.

# "" stands for a missing trailer; `each` would drop a null.
const IMPACT_VALUES = ["refactor" "behavior" "breaking" "Refactor" "BEHAVIOR" "chore" ""]

def gen-impacts [key: string] {
    0..<(1 + (pick $"($key)/count" 5)) | each {|i| pick-from $"($key)/($i)" $IMPACT_VALUES }
}

def with-trailer [key: string, impact: any] {
    let title = (gen-title $"($key)/title")
    let body = if (pick $"($key)/body" 2) == 0 { "" } else { $"\n\n(gen-title $'($key)/body-text')" }
    if ($impact | is-empty) { $"($title)($body)\n" } else { $"($title)($body)\n\nImpact: ($impact)\n" }
}

for-all "parse-impact reads the trailer case-insensitively" {|key|
    let impact = (pick-from $"($key)/impact" $IMPACT_VALUES)
    assert equal (parse-impact (with-trailer $key $impact)) ($impact | str lowercase)
}

for-all "description-body drops the subject and the trailer" {|key|
    let impact = (pick-from $"($key)/impact" ["refactor" "behavior" "breaking"])
    let description = (with-trailer $key $impact)
    let body = (description-body $description)
    assert equal (parse-impact $body) ""
    assert equal $body ($description | lines | skip 1 | drop 1 | str join "\n" | str trim)
}

for-all "combine-impacts never mixes refactors with user-facing changes" {|key|
    let impacts = (gen-impacts $key | each {|impact| $impact | str lowercase })
    let result = (combine-impacts $impacts)
    assert (($result.impact == null) != ($result.problem == null)) "exactly one of impact and problem"
    if ($impacts | any {|impact| $impact not-in $IMPACTS }) {
        assert equal $result.impact null
    } else if ($impacts | all {|impact| $impact == "refactor" }) {
        assert equal $result.impact "refactor"
    } else if "refactor" in $impacts {
        assert equal $result.impact null
    } else {
        assert equal $result.impact (if "breaking" in $impacts { "breaking" } else { "behavior" })
    }
}

for-all "next-version is unique and increments per day" {|key|
    let dates = ["2026.09.26" "2026.09.27" "2026.10.01"]
    mut tags = []
    for i in 0..<(pick $"($key)/count" 12) {
        let date = (pick-from $"($key)/($i)" $dates)
        let version = (next-version $date $tags)
        assert ($version not-in $tags) $"($version) was already released"
        assert ($version | str starts-with $"($date).")
        $tags = ($tags | append $version)
    }
    for date in $dates {
        let serials = ($tags | where {|tag| $tag | str starts-with $"($date)." } | each {|tag| $tag | split row "." | last | into int })
        if ($serials | is-not-empty) {
            assert equal $serials (1..($serials | length) | each {|n| $n })
        }
    }
}

for-all "plan-order keeps published topics first and refactors early" {|key|
    let topics = (0..<(pick $"($key)/count" 8) | each {|i|
        let published = (pick $"($key)/pr/($i)" 2) == 0
        {
            tip: $"t($i)"
            bookmark: (if $published { $"b($i)" } else { null })
            impact: (pick-from $"($key)/impact/($i)" ["refactor" "behavior" "breaking" null])
            created: (pick $"($key)/time/($i)" 1000)
        }
    })
    let ordered = (plan-order $topics)
    assert equal ($ordered | length) ($topics | length)
    # Two workspaces see the topics in different orders; both must pick the
    # same base, or each tells the other to publish first.
    assert equal ($ordered | get tip) (plan-order ($topics | reverse) | get tip)
    $ordered | window 2 | each {|pair|
        let a = ($pair | first)
        let b = ($pair | last)
        assert (($a.bookmark != null) or ($b.bookmark == null)) "an unpublished topic precedes a published one"
        if (($a.bookmark == null) == ($b.bookmark == null)) {
            assert ((impact-order $a.impact) <= (impact-order $b.impact)) "a user-facing topic precedes a refactor"
        }
    } | ignore
}

def gen-workspace-facts [key: string] {
    let flag = {|name| (pick $"($key)/($name)" 2) == 0 }
    {
        name: (pick-from $"($key)/name" ["default" "topic" "other"])
        current: (do $flag current)
        exists: (do $flag exists)
        git_worktree: (do $flag git)
        codex_worktree: (do $flag codex)
        owner: (pick-from $"($key)/owner" ["none" "active" "delivered" "discarded" "released"])
        stale: (do $flag stale)
        error: (if (do $flag error) { "unreadable" } else { null })
        pending: (do $flag pending)
    }
}

for-all "prune never removes a workspace that is live or unknown" {|key|
    let facts = (gen-workspace-facts $key)
    if (prune-verdict $facts) == null {
        assert ($facts.name != "default") "prune removed the default workspace"
        assert (not $facts.current) "prune removed the current workspace"
        if $facts.exists {
            assert (not $facts.git_worktree) "prune removed a Git worktree"
            assert (not $facts.codex_worktree) "prune removed a Codex worktree"
            assert ($facts.owner != "active") "prune removed an owned workspace"
            assert (not $facts.stale) "prune removed an unrefreshed workspace"
            assert ($facts.error == null) "prune removed an unreadable workspace"
            assert (not $facts.pending) "prune removed undelivered work"
        }
    }
}

for-all "prune reclaims every released, delivered workspace" {|key|
    let facts = (gen-workspace-facts $key | merge {
        name: "topic" current: false exists: true git_worktree: false codex_worktree: false
        stale: false error: null
    })
    let owner = (pick-from $"($key)/released" ["none" "delivered" "discarded" "released"])
    let delivered = not $facts.pending
    assert equal ((prune-verdict ($facts | upsert owner $owner)) == null) $delivered
}

# Topic guard: the working copy must not wander off the topic that
# `jj-ci start` recorded, and the interactive `jj new` guard only inspects
# invocations that would move the working copy.

def gen-topic-facts [key: string] {
    let flag = {|name| (pick $"($key)/($name)" 2) == 0 }
    {
        recorded: (do $flag recorded)
        visible: (do $flag visible)
        landed: (do $flag landed)
        ancestor: (do $flag ancestor)
        working_copy_empty: (do $flag working_copy_empty)
        topic_empty: (do $flag topic_empty)
        topic: "t"
    }
}

for-all "a topic below the working copy, landed, or gone is never stranded" {|key|
    let facts = (gen-topic-facts $key)
    for safe in [{ ancestor: true } { landed: true } { visible: false } { recorded: false } { topic_empty: true }] {
        assert (not (topic-stranded ($facts | merge $safe))) $"stranded despite ($safe | to nuon)"
    }
}

for-all "an empty working copy beside unlanded topic work is stranded" {|key|
    let facts = (gen-topic-facts $key | merge {
        recorded: true visible: true landed: false ancestor: false working_copy_empty: true topic_empty: false
    })
    assert (topic-stranded $facts) "`jj new main` beside the topic went unnoticed"
}

const JJ_NEW_CASES = [
    [args expected];
    [["log"] null]
    [["new"] null]
    [["new" "-m" "later"] null]
    [["new" "-m" "main"] null]
    [["new" "main"] ["main"]]
    [["new" "main@tangled" "other"] ["main@tangled" "other"]]
    [["new" "-m" "fresh" "main"] ["main"]]
    [["new" "--message=fresh" "main"] ["main"]]
    [["new" "-A" "main"] ["main"]]
    [["new" "--insert-after=main"] ["main"]]
    [["new" "-o" "main"] ["main"]]
    [["new" "--no-edit" "main"] null]
    [["new" "main" "--no-edit"] null]
    [["new" "-B" "main"] null]
    [["new" "-R" "/elsewhere" "main"] null]
    [["new" "--at-op=abc" "main"] null]
    [["new" "--color" "never" "main"] ["main"]]
]

for case in $JJ_NEW_CASES {
    assert equal (jj-new-parents $case.args) $case.expected $"jj ($case.args | str join ' ')"
}
print $"ok jj new parents \(($JJ_NEW_CASES | length) cases)"

# Ownership records (TLA: DeliveredRecordIsTrue). A hand-edited `finished`
# must never read as a delivered topic.

owner-status-properties {|record| owner-status $record }

# jj-ci unclaim (TLA: Unclaim, UnclaimOnlyOrphans, ClaimOnlyWhileActive).

def gen-unclaim-facts [key: string] {
    {
        status: (pick-from $"($key)/status" ["none" "active" "delivered" "discarded" "released"])
        at_owner_change: (flag $"($key)/at")
        claim: (flag $"($key)/claim")
        legacy: (flag $"($key)/legacy")
    }
}

for-all "unclaim rewrites every ended legacy record and no active one" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    let ended = $facts.status in ["delivered" "discarded" "released"]
    assert equal $verdict.normalize ($facts.legacy and $facts.status != "active")
    if $verdict.normalize { assert (not $verdict.release) "normalized and released at once" }
    if $ended and $facts.legacy { assert $verdict.normalize }
}

for-all "unclaim never frees a change that is checked out" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    if $facts.status == "active" and $facts.at_owner_change {
        assert (not $verdict.release) "released a checked-out change"
        assert (not $verdict.clear_claim) "cleared the claim of a checked-out change"
        assert ($verdict.refuse != null) "gave no reason to use finish or abandon"
    }
}

for-all "unclaim frees every orphaned active claim" {|key|
    let facts = (gen-unclaim-facts $key | upsert status "active" | upsert at_owner_change false)
    let verdict = (unclaim-verdict $facts)
    assert $verdict.release "left an orphaned claim active"
    assert $verdict.clear_claim "released the record but kept its claim"
    assert equal $verdict.refuse null
}

for-all "unclaim only ever changes an active record" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    if $verdict.release { assert equal $facts.status "active" }
}

for-all "unclaim leaves no claim without an active owner" {|key|
    let facts = (gen-unclaim-facts $key)
    let verdict = (unclaim-verdict $facts)
    let owner_active_after = ($facts.status == "active" and not $verdict.release)
    let claim_after = ($facts.claim and not $verdict.clear_claim)
    if $verdict.refuse == null {
        assert ((not $claim_after) or $owner_active_after) "a claim outlived its owner"
    }
}
