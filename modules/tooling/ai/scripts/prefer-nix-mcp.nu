# Claude Code PostToolUse hook: when a shell command or file tool answers a
# Nix knowledge question by hand (nix search, nixpkgs evaluation, raw
# /nix/store reads, GitHub API calls against NixOS), remind the agent that
# the Nix MCP server answers it from the pinned or indexed source. Each kind
# of reminder is given once per session. The hook never blocks a call.

const reminders = {
  search: "Look packages up with the Nix MCP server instead of `nix search`, `nix-env -qa`, or nix-locate: `nix {action: info, query: NAME}` confirms an attribute is in the channel, `{action: search, query: X}` finds candidates, and `{action: search, type: programs, query: BIN}` finds the package that ships a binary."
  eval: "Look nixpkgs attributes, versions, and options up with the Nix MCP server instead of evaluating nixpkgs: `nix {action: info, query: NAME}` for a package, `{action: info, type: option, query: PATH}` for a NixOS option (add `source: home-manager` for Home Manager), and `nix_versions` for version history. Keep `nix eval` for this repository's own flake outputs."
  store: "Read pinned flake inputs and store paths with the Nix MCP server instead of shell or file tools: `nix {action: flake-inputs, type: ls|read, query: \"INPUT:path\"}` reads an input such as den, home-manager, or nixpkgs at its locked revision, and `{action: store, type: ls|read, query: /nix/store/...}` reads any other store path."
  github: "Look nixpkgs and NixOS facts up with the Nix MCP server instead of the GitHub API or search.nixos.org: `nix {action: info|search ...}` covers packages and options, `{action: search, source: wiki|nix-dev|noogle}` covers documentation and lib functions, and `nix_versions` covers which commit shipped a version."
}

def classify [text: string] {
  let checks = [
    [kind pattern];
    [search '\bnix\s+search\b|\bnix-env\s+(-\w*q|--query)|\bnix-locate\b']
    [eval '\bnix(-instantiate|\s+(eval|repl))\b.*(nixpkgs#|<nixpkgs>|github:NixOS/)']
    [store '/nix/store/']
    [github '\bgh\s+api\b.*\bNixOS/|search\.nixos\.org|api\.github\.com/repos/NixOS/']
  ]
  $checks | where {|c| $text =~ $c.pattern } | get kind
}

# The text a call reached for: a shell command, or a file tool's path.
def call-text [payload: record] {
  let input = ($payload.tool_input? | default {})
  match ($payload.tool_name? | default "") {
    "Bash" => ($input.command? | default "")
    "Read" => ($input.file_path? | default "")
    "Glob" | "Grep" => ([$input.path? $input.pattern?] | compact | str join " ")
    $tool if $tool =~ 'nushell__evaluate$' => ($input.input? | default "")
    _ => ""
  }
}

# Record a reminder for the session; false when it was already given.
def first-time [session: string, kind: string] {
  let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join claude-code nix-mcp-reminders)
  let marker = ($dir | path join $"($session | str replace --all --regex '[^A-Za-z0-9_-]' '_')-($kind)")
  if ($marker | path exists) { return false }
  mkdir $dir
  "" | save --force $marker
  true
}

def main [] {
  let input = $in
  try {
    let payload = ($input | into string | from json)
    let session = ($payload.session_id? | default "unknown")
    let kinds = (classify (call-text $payload) | where {|kind| first-time $session $kind })
    if ($kinds | is-empty) { return }
    let context = ($kinds | each {|kind| $reminders | get $kind } | str join "\n\n")
    print ({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $context } } | to json --raw)
  }
}
