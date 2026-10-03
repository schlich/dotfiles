# Run executable knowledge documents in the Nix environment they declare.
#
# A document opts in with `environment: NAME` in its frontmatter; documents
# without it use `base`. Environments are workbench/environments/NAME.nix.

const manifest = "@manifest@"
const iwe = "@iwe@"

def environments [] {
    open $manifest
}

# The YAML frontmatter of a Markdown file, or an empty record.
def frontmatter [file: path] {
    let text = open --raw $file
    if not ($text | str starts-with "---\n") {
        return {}
    }
    $text
    | lines
    | skip 1
    | take until {|line| $line == "---" }
    | str join "\n"
    | from yaml
    | default {}
}

# marimo's own rule: a fence whose attributes name marimo, python, or sql.
def is-executable [file: path] {
    open --raw $file
    | lines
    | any {|line| $line =~ '^\s*(`{3,}|~{3,})\s*[\w-]*\s*\{[^}]*\b(marimo|python|sql)\b' }
}

def resolve [file: path] {
    let name = (frontmatter $file | get --optional environment | default "base")
    let known = (environments)
    if $name not-in ($known | columns) {
        error make {
            msg: $"($file): unknown environment '($name)'; declared: ($known | columns | str join ', ')"
        }
    }
    {name: $name} | merge ($known | get $name)
}

def --wrapped marimo-in [file: path, ...args: string] {
    let environment = (resolve $file)
    with-env {
        WORKBENCH_ENVIRONMENT: $environment.name
        PATH: ($env.PATH | prepend $"($environment.runtime)/bin")
    } {
        ^$"($environment.runtime)/bin/marimo" ...$args
    }
}

# Run executable knowledge documents in their declared Nix environments.
def main [] {
    help main
}

# List the declared environments.
def "main environments" [] {
    environments | transpose name spec | each {|row| {name: $row.name} | merge $row.spec }
}

# Show which environment a document resolves to.
def "main env" [file: path] {
    resolve $file
}

# Edit a document with marimo in its environment. This is a local workflow:
# the kernel runs as you, without a sandbox. Use marimohub for isolation.
def --wrapped "main edit" [file: path, ...rest: string] {
    marimo-in $file edit $file ...$rest
}

# Serve a document read-only as a marimo app in its environment.
def --wrapped "main run" [file: path, ...rest: string] {
    marimo-in $file run $file ...$rest
}

# Execute a document headlessly and write the rendered HTML view.
def "main export" [file: path, --output (-o): path] {
    let target = ($output | default ($file | path parse | update extension html | path join))
    marimo-in $file export html $file -o $target
}

# Validate the knowledge graph and every executable document under ROOT.
def "main check" [root: path = "."] {
    cd $root
    ^$iwe schema validate
    let library = (open .iwe/config.toml | get --optional library.path | default "")
    let documents = (glob $"($library | path expand)/**/*.md")
    for document in $documents {
        let environment = (resolve $document)
        if (is-executable $document) {
            marimo-in $document check $document
            print $"($document | path relative-to $env.PWD): ($environment.name)"
        }
    }
}

# Push the committed tree under ROOT-PATH to a marimohub push-mode source.
#
# The repository stays authoritative: the hub stores each upload as an
# immutable version and serves it read-only. MARIMOHUB_SYNC_URL and
# MARIMOHUB_SYNC_TOKEN come from the notebook's sync settings.
def "main sync" [
    --repo: string # The repository name the source was created with
    --branch: string = "main"
    --root-path: string = "workbench"
    --rev: string = "HEAD" # A Git revision; in a colocated JJ repository HEAD is @-
] {
    let url = $env.MARIMOHUB_SYNC_URL? | default ""
    let token = $env.MARIMOHUB_SYNC_TOKEN? | default ""
    if ($url | is-empty) or ($token | is-empty) {
        error make { msg: "set MARIMOHUB_SYNC_URL and MARIMOHUB_SYNC_TOKEN" }
    }
    if ($repo | is-empty) {
        error make { msg: "pass --repo with the repository name the source was created with" }
    }
    let commit = (^git rev-parse $rev | str trim)
    let archive = (^git archive --format=tar.gz $"($commit):($root_path)" | into binary)
    (
        http post
            --content-type application/gzip
            --headers {
                Authorization: $"Bearer ($token)"
                X-Marimohub-Repo: $repo
                X-Marimohub-Branch: $branch
                X-Marimohub-Root-Path: $root_path
                X-Marimohub-Commit: $commit
                X-Marimohub-Archive-Format: "tar.gz"
            }
            $url
            $archive
    )
}
