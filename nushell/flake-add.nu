# Add a GitHub repository as an input of a flake.nix: write the input block,
# with a `follows` line for every input the two flakes share and a comment
# taken from the flake's description, lock only that input, and print how its
# outputs could be wired in. The wiring stays a person's (or agent's) call.
# A flake.nix whose inputs block this cannot find goes through `fh add`, which
# edits through the Nix syntax tree, and gets the same block in place of the
# bare `NAME.url` line `fh add` writes.

const SYSTEM = "x86_64-linux"

def run-command [label: string, command: closure] {
    let result = (do $command | complete)
    if $result.exit_code != 0 {
        error make { msg: $"($label) failed: ($result.stderr | str trim)" }
    }
    $result.stdout
}

# OWNER/REPO, github:OWNER/REPO[/REF], or a GitHub URL, as github:OWNER/REPO[/REF].
def parse-ref [ref: string, rev?: string] {
    let found = ($ref | parse --regex '^(?:github:|https?://github\.com/)?(?<owner>[\w.-]+)/(?<repo>[\w.-]+?)(?:\.git)?(?:/(?:tree/)?(?<rest>[^?#]+?))?/?$')
    if ($found | is-empty) {
        error make { msg: $"`($ref)` is not OWNER/REPO, github:OWNER/REPO, or a GitHub URL." }
    }
    let found = ($found | first)
    let pin = if $rev != null { $rev } else { $found.rest }
    let url = if ($pin | is-empty) { $"github:($found.owner)/($found.repo)" } else { $"github:($found.owner)/($found.repo)/($pin)" }
    { owner: $found.owner, repo: $found.repo, url: $url }
}

def wrap [text: string, width: int] {
    $text | split row ' ' | where $it != '' | reduce --fold [''] {|word, acc|
        let line = ($acc | last)
        if ($line | is-empty) {
            $acc | drop | append $word
        } else if (($line | str length) + 1 + ($word | str length)) > $width {
            $acc | append $word
        } else {
            $acc | drop | append $"($line) ($word)"
        }
    }
}

# The input's lines, indented for a top-level `inputs = { ... };` block.
def input-block [name: string, url: string, follows: list<string>, is_flake: bool, comment: string] {
    let comment_lines = if ($comment | is-empty) { [] } else { wrap $comment 74 | each {|l| $"    # ($l)" } }
    let body = if $is_flake {
        $follows | each {|f| $"      inputs.($f).follows = \"($f)\";" }
    } else {
        ['      flake = false;']
    }
    $comment_lines | append $"    ($name) = {" | append $"      url = \"($url)\";" | append $body | append '    };'
}

# The flake.nix lines with the block appended to `inputs`, and how it got there.
def insert-block [flake: path, name: string, url: string, block: list<string>, follows: list<string>, is_flake: bool, comment: string] {
    let lines = (open --raw $flake | lines)
    let outputs = ($lines | enumerate | where item =~ '^\s*outputs\s*=' | get index)
    let closes = if ($outputs | is-empty) {
        []
    } else {
        $lines | enumerate | where {|l| $l.index < ($outputs | first) and $l.item == '  };' } | get index
    }
    if ($closes | is-not-empty) {
        let at = ($closes | last)
        return { via: "inputs block", lines: ($lines | take $at | append $block | append ($lines | skip $at)) }
    }
    # The installed command pins fh by setting FLAKE_ADD_FH.
    let fh = ($env.FLAKE_ADD_FH? | default "fh")
    let edited = (run-command "fh add" { ^$fh add $url --input-name $name --insertion-location bottom --flake-path $flake --dry-run } | lines)
    # fh writes `NAME.url = ...;` inside an inputs block, or `inputs.NAME.url`
    # at the top level; the rest of the input follows in the same dotted form.
    let hits = ($edited | enumerate | where item =~ ('^\s*(inputs\.)?' + $name + '\.url\s*='))
    if ($hits | is-empty) {
        return { via: "fh add (its own line, without follows or comment)", lines: $edited }
    }
    let at = ($hits | first | get index)
    let found = ($hits | first | get item | parse --regex ('^(?<indent>\s*)(?<prefix>(?:inputs\.)?)' + $name + '\.url') | first)
    let attr = $"($found.indent)($found.prefix)($name)"
    let above = if ($comment | is-empty) { [] } else { wrap $comment 74 | each {|l| $"($found.indent)# ($l)" } }
    let below = if $is_flake {
        $follows | each {|f| $"($attr).inputs.($f).follows = \"($f)\";" }
    } else {
        [$"($attr).flake = false;"]
    }
    {
        via: "fh add, which also names the input in the outputs arguments"
        lines: ($edited | take $at | append $above | append ($edited | get $at) | append $below | append ($edited | skip ($at + 1)))
    }
}

# Where each kind of output usually goes in the dotfiles repository.
def wiring [name: string, is_flake: bool, outputs: any] {
    if not $is_flake {
        return [$"Not a flake: use files as \"${inputs.($name)}/PATH\"; agent skills go in modules/tooling/ai/shared-skills.nix."]
    }
    if $outputs == null {
        return ["Outputs not inspected (--no-show): run `nix flake show` on the URL to see them."]
    }
    if ($outputs.error? != null) {
        return [$"`nix flake show` failed, so wire it by hand: ($outputs.error)"]
    }
    let packages = ($outputs | get -o packages | default {} | get -o $SYSTEM | default {} | columns)
    let home_modules = ([homeManagerModules homeModules] | each {|kind|
        $outputs | get -o $kind | default {} | columns | each {|m| $"inputs.($name).($kind).($m)" }
    } | flatten)
    let nixos_modules = ($outputs | get -o nixosModules | default {} | columns)
    let overlays = ($outputs | get -o overlays | default {} | columns)
    [
        ...($packages | each {|p| $"Package: add inputs.($name).packages.${pkgs.stdenv.hostPlatform.system}.($p) to home.packages in modules/home/packages.nix." })
        ...($home_modules | each {|m| $"Home Manager module: `imports = [ ($m) ];` in a module under modules/programs/, as dicta.nix does." })
        ...($nixos_modules | each {|m| $"NixOS module: inputs.($name).nixosModules.($m) belongs in a Den aspect for the hosts that need it." })
        ...($overlays | each {|o| $"Overlay: inputs.($name).overlays.($o) goes in the overlay list in den/aspects/home-manager-host.nix." })
    ] | default --empty ["The flake exports nothing for this repository to wire; check `nix flake show` by hand."]
}

def main [
    ref: string          # OWNER/REPO, github:OWNER/REPO[/REF], or a GitHub URL.
    --name: string       # The input's name; defaults to the repository's name.
    --rev: string        # A branch, tag, or commit to pin; defaults to the default branch.
    --comment: string    # Why the input exists; defaults to the flake's description.
    --keep: string       # Comma-separated shared inputs to leave unfollowed, such as nixpkgs when the flake needs its own pin.
    --flake: path = "flake.nix" # The flake.nix to edit.
    --dry-run            # Print the block and the wiring without editing or locking.
    --force              # Add the input even when nixpkgs already ships a package of that name.
    --no-show            # Skip `nix flake show`, which evaluates the flake's outputs.
    --json               # Print the report as JSON, for agents.
] {
    let report = (add-input $ref $name $rev $comment $keep $flake $dry_run $force $no_show)
    if $json { $report | to json } else { $report }
}

def add-input [
    ref: string, name: any, rev: any, comment: any, keep: any, flake: path,
    dry_run: bool, force: bool, no_show: bool
] {
    let flake = ($flake | path expand)
    if not ($flake | path exists) {
        error make { msg: $"($flake) does not exist." }
    }
    let dir = ($flake | path dirname)
    let source = (parse-ref $ref $rev)
    let name = ($name | default ($source.repo | str lowercase | str replace --all '.' '-'))
    if $name !~ '^[A-Za-z_][A-Za-z0-9_-]*$' {
        error make { msg: $"`($name)` is not a usable input name; pass one with --name." }
    }
    let ours = (run-command "reading this flake's inputs" { ^nix eval --json --file $flake inputs --apply builtins.attrNames } | from json)
    if $name in $ours {
        error make { msg: $"`($name)` is already an input of ($flake)." }
    }

    let fetched = (run-command $"fetching ($source.url)" { ^nix flake prefetch --json $source.url } | from json)
    let is_flake = ($"($fetched.storePath)/flake.nix" | path exists)
    let meta = if $is_flake {
        run-command "reading the flake's metadata" { ^nix flake metadata --json --no-write-lock-file $source.url } | from json
    } else {
        {}
    }
    let theirs = ($meta.locks?.nodes?.root?.inputs? | default {} | columns)
    let keep = ($keep | default '' | split row ',' | str trim | where $it != '')
    let follows = ($theirs | where {|i| $i in $ours and $i not-in $keep })
    let unfollowed = ($theirs | where {|i| $i not-in $follows })

    let outputs = if $is_flake and not $no_show {
        let shown = (do { ^nix flake show --json --no-write-lock-file $source.url } | complete)
        if $shown.exit_code == 0 { $shown.stdout | from json } else { { error: ($shown.stderr | str trim | lines | last) } }
    } else {
        null
    }

    let default_package = ($outputs | default {} | get -o packages | default {} | get -o $SYSTEM | default {} | get -o default)
    let in_nixpkgs = if $default_package == null {
        null
    } else {
        let pname = ($default_package.name? | default $source.repo | parse --regex '^(?<p>.+?)(?:-\d[^-]*)?$' | get 0.p)
        # The package's own name, then the repository's (helix builds helix-term).
        [$pname ($source.repo | str lowercase)] | uniq | each {|candidate|
            let found = (do { ^nix eval --raw --inputs-from $"path:($dir)" $"nixpkgs#($candidate).version" } | complete)
            if $found.exit_code == 0 { { pname: $candidate, version: ($found.stdout | str trim) } }
        } | get -o 0
    }
    if $in_nixpkgs != null and not $force {
        error make { msg: $"nixpkgs already ships ($in_nixpkgs.pname) ($in_nixpkgs.version): add pkgs.($in_nixpkgs.pname) instead, or pass --force if upstream's build is needed." }
    }

    let comment = ($comment | default ($meta.description? | default ''))
    let block = (input-block $name $source.url $follows $is_flake $comment)
    let next = (wiring $name $is_flake $outputs
        | append (if $in_nixpkgs != null { [$"Declare dotfiles.nixpkgsWatch.($in_nixpkgs.pname) next to the wiring: nixpkgs ships ($in_nixpkgs.version)."] } else { [] }))
    let report = {
        input: $name
        url: $source.url
        flake: $is_flake
        follows: $follows
        unfollowed: $unfollowed
        block: ($block | str join "\n")
        next: $next
    }
    if $dry_run {
        return ($report | insert written false)
    }

    let edit = (insert-block $flake $name $source.url $block $follows $is_flake $comment)
    let content = ($edit.lines | str join "\n" | str trim --right | $"($in)\n")
    let candidate = (mktemp --tmpdir flake-add.XXXXXX)
    $content | save --force $candidate
    let check = (do { ^nix eval --raw --file $candidate $"inputs.($name).url" } | complete)
    rm $candidate
    if $check.exit_code != 0 {
        error make { msg: $"The edited flake.nix does not evaluate, so it was left alone: ($check.stderr | str trim)" }
    }
    $content | save --force $flake
    run-command $"locking ($name)" { ^nix flake update $name --flake $"path:($dir)" }
    $report | insert written $flake | insert via $edit.via
}
