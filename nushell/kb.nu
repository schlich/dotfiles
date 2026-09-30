# Personal knowledge base: an IWE workspace in its own JJ repository.
#
# Set KB_ROOT to use a workspace other than ~/kb.

def kb-root [] {
    $env.KB_ROOT? | default ($env.HOME | path join kb)
}

# Open the knowledge base in Helix.
export def --env kb [] {
    cd (kb-root)
    ^hx .
}

# Search notes by title and body; returns one row per document.
export def "kb find" [...terms: string, --limit (-l): int = 20] {
    let query = ($terms | str join " ")
    cd (kb-root)
    ^iwe find --fuzzy $query --lexical $query --limit $limit -f json | from json
}

# Open today's daily note, the capture inbox (Mod+Shift+N), creating it on
# first use.
export def "kb today" [] {
    let now = (date now)
    let key = $"daily/($now | format date '%Y-%m-%d')"
    cd (kb-root)
    # The same typed hub `iwe attach --to daily` appends to, so captures and
    # recorded memories share one page per day.
    if not ($"($key).md" | path exists) {
        let created = ($"---\ntype: daily\n---\n\n# ($now | format date '%b %d, %Y')\n" | ^iwe create $key --content - | complete)
        if $created.exit_code != 0 {
            error make { msg: ($created.stderr | str trim) }
        }
    }
    ^hx $"($key).md"
}

# Validate schemas and report broken links, orphans, and near-duplicates.
export def "kb check" [] {
    cd (kb-root)
    ^iwe schema validate
    ^iwe stats
    ^iwe stats similarity
}
