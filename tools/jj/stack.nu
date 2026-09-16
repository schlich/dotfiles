const stack_template = 'change_id ++ "\t" ++ commit_id ++ "\t" ++ description.first_line() ++ "\t" ++ author.email() ++ "\t" ++ parents.map(|p| p.change_id()).join(",") ++ "\t" ++ bookmarks.map(|b| b.name()).join(",") ++ "\t" ++ current_working_copy ++ "\t" ++ conflict ++ "\n"'

def stack-revisions [] {
    let result = (^jj log -r 'trunk()::@' --reversed --no-graph -T $stack_template | complete)
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout
    | lines
    | where {|line| $line | str trim | is-not-empty }
    | each {|line|
        let fields = ($line | split row "\t")
        {
            change_id: ($fields | get 0)
            commit_id: ($fields | get 1)
            description: ($fields | get 2)
            author: ($fields | get 3)
            parents: ($fields | get 4)
            bookmarks: ($fields | get 5)
            current: (($fields | get 6) == "true")
            conflicted: (($fields | get 7) == "true")
        }
    }
}

def main [--json] {
    let rows = (stack-revisions)
    if $json { $rows | to json --raw } else {
        print "change-id                         commit-id                                 description"
        for row in $rows {
            let marker = if $row.current { "*" } else { " " }
            let conflict = if $row.conflicted { " CONFLICT" } else { "" }
            print $"($marker) ($row.change_id) ($row.commit_id) ($row.description)($conflict)"
        }
    }
}

def "main new" [] {
    ^jj new
    print "Created the next empty change. Describe it with `jj desc -m '...'` or `jj-describe`."
}

def "main edit" [revision: string] {
    ^jj edit $revision
}

def "main diff" [] {
    ^jj diff -r 'trunk()..@'
}

def "main each" [] {
    ^jj log -r 'trunk()::@' --reversed --patch
}

def "main push" [--remote: string = "tangled"] {
    let rows = (stack-revisions)
    if ($rows | is-empty) { error make { msg: "No stack found from trunk() to @." } }
    print "About to push the current stack with native JJ change semantics:"
    $rows | select change_id commit_id description bookmarks conflicted | table
    print $"Remote: ($remote). No push has happened yet; confirm by running `jj git push --remote ($remote) --change @`."
    let answer = (input "Push this stack? [y/N] ")
    if (($answer | str lowercase) != "y") { print "Cancelled."; return }
    ^jj git push --remote $remote --change @
}
