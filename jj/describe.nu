def main [
    revset: string = "@"
    --agent (-a): string = "general"
] {
    ^jj run -r $revset -- nu $env.CURRENT_FILE describe-one $agent
}

def "main describe-one" [agent: string] {
    let change_id = $env.JJ_CHANGE_ID?

    if $change_id == null {
        error make { msg: "jj-describe must be run through jj run" }
    }

    ^ai-run --agent $agent $"Describe changeset ($change_id). Inspect it with `jj show -r ($change_id)`, then update only its description with `jj desc -r ($change_id) -m DESCRIPTION`. Write a concise imperative subject of at most 72 characters and an optional body explaining why. Do not modify tracked files, create commits, or modify any other changeset."
}
