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
const BLOCKING = ["conflicted" "parent not local" "waiting on parent"]
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

# Open PRs with unique head branches. A base is main, another PR's head
# (possibly forming a cycle), or a branch that is no longer open.
def gen-prs [key: string] {
    let count = (pick $"($key)/count" 8)
    let heads = (0..<$count | each {|i| $"b($i)" })
    let bases = (["main" "main" "gone"] ++ $heads)
    shuffle $"($key)/order" (0..<$count | each {|i|
        {
            number: (100 + $i)
            headRefName: ($heads | get $i)
            baseRefName: (pick-from $"($key)/base/($i)" $bases)
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

# PR heads that reach main through a chain of open PRs, by fixpoint.
def rooted-heads [prs: list] {
    mut rooted = ["main"]
    loop {
        let known = $rooted
        let next = ($prs | where {|pr| $pr.baseRefName in $known and $pr.headRefName not-in $known } | get headRefName)
        if ($next | is-empty) { break }
        $rooted = ($rooted ++ $next)
    }
    $rooted | where {|head| $head != "main" }
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

for-all "stack-order partitions the open PRs" {|key|
    let prs = (gen-prs $key)
    let order = (stack-order $prs)
    let numbers = ($order.ordered ++ $order.unrooted | get number? | default [])
    assert equal ($numbers | sort) ($prs | get number? | default [] | sort)
    assert equal ($numbers | uniq | length) ($numbers | length)
}

for-all "stack-order is topological" {|key|
    let order = (stack-order (gen-prs $key))
    $order.ordered | enumerate | each {|entry|
        let earlier = ($order.ordered | first $entry.index | get headRefName? | default [])
        assert ($entry.item.baseRefName == "main" or $entry.item.baseRefName in $earlier) $"#($entry.item.number) precedes its parent ($entry.item.baseRefName)"
    } | ignore
}

for-all "stack-order roots exactly the PRs that reach main" {|key|
    let prs = (gen-prs $key)
    let order = (stack-order $prs)
    assert equal ($order.ordered | get headRefName? | default [] | sort) (rooted-heads $prs | sort)
}

for-all "stack-order ignores input order" {|key|
    let prs = (gen-prs $key)
    let left = (stack-order $prs)
    let right = (stack-order (shuffle $"($key)/again" $prs))
    assert equal ($left.unrooted | get number? | default [] | sort) ($right.unrooted | get number? | default [] | sort)
}

# Refresh: a blocked parent blocks everything stacked above it (TLA: a
# conflicted topic is never published, delivered, or finished).

for-all "refresh never touches PRs above a blocked parent" {|key|
    let prs = (gen-prs $key)
    let outcome = {|pr| pick-from $"($key)/state/($pr.number)" $REFRESH_STATES }
    let results = (refresh-outcomes (stack-order $prs) {|pr|
        { pr: $pr.number branch: $pr.headRefName state: (do $outcome $pr) }
    })
    assert equal ($results | get pr? | default [] | sort) ($prs | get number? | default [] | sort)
    for result in $results {
        let pr = ($prs | where number == $result.pr | first)
        let parent = ($results | where branch == $pr.baseRefName | get 0?)
        if $result.state == "base is not main or an open PR" {
            assert ($pr.headRefName not-in (rooted-heads $prs))
        } else if $parent != null and $parent.state in $BLOCKING {
            assert equal $result.state "waiting on parent"
        } else {
            assert equal $result.state (do $outcome $pr)
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
