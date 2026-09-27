# Property-based tests for the pure planning helpers in jj/ci.nu, derived from
# the invariants in jj/JjCi.tla. Run with:
#
#   nu --no-config-file -c "source tests/jj-ci-properties.nu"
#
# Sourcing through `-c` defines ci.nu's helpers without running its `main`.
# Randomness is keyed by PBT_SEED, property name, and case number, so a
# failure report is enough to replay it exactly.

use std/assert

source ../jj/ci.nu

const CASES = 100
const BLOCKING = ["conflicted" "waiting on parent"]
const TITLE_CHARS = ["a" "b" "z" "Q" "0" "7" " " "  " "-" "--" "_" "." "/" ":" "!" "é" "日"]
const CHANGE_CHARS = ["k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z"]
const REFRESH_STATES = [
    "current" "pushed" "ready to push" "conflicted"
    "parent not local" "no local bookmark" "checked out"
]

def seed [] { $env.PBT_SEED? | default "0" }

# A deterministic integer in 0..<n for the given key.
def pick [key: string, n: int] {
    if $n <= 0 { return 0 }
    # The leading 1 keeps `into int` from reading a 0b or 0x prefix.
    let hex = ($key | hash sha256 | str substring 0..11)
    ($"1($hex)" | into int --radix 16) mod $n
}

def pick-from [key: string, items: list] {
    $items | get (pick $key ($items | length))
}

def shuffle [key: string, items: list] {
    $items | enumerate | sort-by {|entry| pick $"($key)/($entry.index)" 1000000007 } | get item
}

# Half of the titles are long enough to exercise the 48-character cut.
def gen-title [key: string] {
    let length = if (pick $"($key)/long" 2) == 0 { 60 + (pick $"($key)/len" 60) } else { pick $"($key)/len" 40 }
    0..<$length
    | each {|i| pick-from $"($key)/($i)" $TITLE_CHARS }
    | str join
}

def gen-change-id [key: string] {
    0..<32 | each {|i| pick-from $"($key)/($i)" $CHANGE_CHARS } | str join
}

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

def for-all [name: string, property: closure] {
    for case in 0..<$CASES {
        let key = $"(seed)/($name)/($case)"
        try {
            do $property $key
        } catch {|error|
            error make { msg: $"property `($name)` failed at PBT_SEED=(seed) case ($case): ($error.msg)" }
        }
    }
    print $"ok ($name) \(($CASES) cases)"
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
        owner: (pick-from $"($key)/owner" ["none" "active" "finished"])
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
    let owner = (pick-from $"($key)/released" ["none" "finished"])
    let delivered = not $facts.pending
    assert equal ((prune-verdict ($facts | upsert owner $owner)) == null) $delivered
}
