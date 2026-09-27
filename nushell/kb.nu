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

# Open today's journal entry, creating it on first use.
export def "kb today" [] {
    let date = (date now | format date "%Y-%m-%d")
    let file = (kb-root | path join journal $"($date).md")
    if not ($file | path exists) {
        mkdir ($file | path dirname)
        $"# ($date)\n" | save $file
    }
    cd (kb-root)
    ^hx $file
}

# Validate schemas and report broken links, orphans, and near-duplicates.
export def "kb check" [] {
    cd (kb-root)
    ^iwe schema validate
    ^iwe stats
    ^iwe stats similarity
}
