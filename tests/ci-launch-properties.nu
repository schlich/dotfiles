# Property-based tests for which jj/ci.nu the `ci` launcher runs. Run with:
#
#   nu --no-config-file -c "source tests/ci-launch-properties.nu"

source pbt.nu
source ../jj/ci-launch.nu

def gen-launch-facts [key: string] {
    {
        has_script: (flag $"($key)/script")
        topic_edits: (flag $"($key)/edits")
        trunk_readable: (flag $"($key)/trunk")
    }
}

for-all "the bundled copy runs exactly outside a repository with jj/ci.nu" {|key|
    let facts = (gen-launch-facts $key)
    assert equal ((launch-choice $facts) == "bundled") (not $facts.has_script)
}

for-all "a topic that edits jj/ci.nu always runs its own copy" {|key|
    let facts = (gen-launch-facts $key | upsert has_script true | upsert topic_edits true)
    assert equal (launch-choice $facts) "topic"
}

for-all "every other workspace runs the trunk copy when it can read it" {|key|
    let facts = (gen-launch-facts $key)
    let trunk = $facts.has_script and (not $facts.topic_edits) and $facts.trunk_readable
    assert equal ((launch-choice $facts) == "trunk") $trunk
}
