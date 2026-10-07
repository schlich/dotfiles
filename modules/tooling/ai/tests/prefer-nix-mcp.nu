# Run the prefer-nix-mcp hook command against sample PostToolUse payloads.
# Usage: nu prefer-nix-mcp.nu <hook command>
def main [command: string] {
  $env.XDG_STATE_HOME = (mktemp --directory)
  let cases = [
    [name tool tool_input session expect];
    ["reminds on nix search" Bash { command: "nix search nixpkgs ripgrep" } a "nix search"]
    ["reminds once per session" Bash { command: "nix search nixpkgs fd" } a null]
    ["reminds on a store read in Nushell" mcp__plugin_hm_nushell__evaluate { input: "open /nix/store/x-source/README.md" } a "flake-inputs"]
    ["reminds on a store Read" Read { file_path: "/nix/store/x-source/flake.nix" } b "flake-inputs"]
    ["reminds on nixpkgs evaluation" Bash { command: "nix eval nixpkgs#hello.version" } a "type: option"]
    ["ignores this flake's outputs" Bash { command: "nix eval --raw path:.#nixosConfigurations.asus.config.system.build.toplevel" } c null]
    ["reminds on the GitHub API" Bash { command: "gh api repos/NixOS/nixpkgs/pulls/1" } a "nix_versions"]
    ["ignores workspace files" Read { file_path: "/home/u/dotfiles/flake.nix" } d null]
    ["ignores other tools" Write { file_path: "/nix/store/x" } e null]
  ]
  let failures = ($cases | each {|c|
    let payload = ({ session_id: $c.session, hook_event_name: PostToolUse, tool_name: $c.tool, tool_input: $c.tool_input } | to json)
    let r = ($payload | ^sh -c $command | complete)
    let out = ($r.stdout | str trim)
    let context = if $out == "" { null } else { $out | from json | get hookSpecificOutput.additionalContext }
    let ok = $r.exit_code == 0 and $r.stderr == "" and (if $c.expect == null { $context == null } else { $context != null and ($context | str contains $c.expect) })
    print $"(if $ok { 'ok  ' } else { 'FAIL' }) prefer-nix-mcp: ($c.name)"
    if not $ok { print $"     stdout: ($r.stdout | to json) stderr: ($r.stderr | to json)" }
    $ok
  } | where {|ok| not $ok } | length)
  if $failures > 0 { exit 1 }
}
