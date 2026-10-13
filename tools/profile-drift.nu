# Report commands served through an imperative Nix profile rather than this
# host's system closure or the devshell.
#
# A host whose configuration declares no Home Manager user keeps whatever a
# one-off `home-manager switch` once installed, and that profile silently
# shadows current packages for every tool the devshell does not carry. Name the
# profile, date it, and list what still comes from it.

def profile-generations [] {
  [
    $"($env.HOME)/.local/state/nix/profiles"
    $"/nix/var/nix/profiles/per-user/($env.USER)"
  ]
  | where {|dir| $dir | path exists }
  | each {|dir| ls --long $dir | where name =~ '-\d+-link$' }
  | flatten
}

def main [] {
  let profile = $"($env.HOME)/.nix-profile"

  if not ($profile | path exists) {
    print "No imperative user profile. Every command comes from the system closure or a devshell."
  } else {
    let root = ($profile | path expand)
    print $"Imperative profile: ($profile)"
    print $"  -> ($root)"

    let gens = (profile-generations)
    if not ($gens | is-empty) {
      let newest = ($gens | sort-by modified | last)
      print $"  newest generation: ($newest.name) ($newest.modified | format date '%Y-%m-%d')"
    }

    # Match on the profile path a command is served *through*, not its final
    # store path: PATH points at the symlink farm, not at the package.
    let prefixes = [
      $profile
      $"($env.HOME)/.local/state/nix/profiles"
      $"/nix/var/nix/profiles/per-user/($env.USER)"
    ]
    let bin = $"($root)/bin"
    let shadowing = if ($bin | path exists) {
      ls $bin
      | get name
      | path basename
      | sort
      | each {|name|
          let hit = (which $name | get --optional 0.path)
          if ($hit != null) and ($prefixes | any {|p| $hit | str starts-with $p }) {
            { command: $name, source: $hit }
          }
        }
    } else { [] }

    print ""
    print $"Commands resolving into that profile: ($shadowing | length)"
    if not ($shadowing | is-empty) {
      print ($shadowing | get command | str join ' ')
    }
  }

  print ""
  let claude = (which claude | get --optional 0.path)
  if $claude == null {
    print "claude is not on PATH."
  } else {
    let actual = (^$claude --version | str trim | split row " " | first)
    let verdict = if $actual == $expected_claude { "current" } else { $"DRIFTED, expected ($expected_claude)" }
    print $"claude ($actual) — ($verdict)"
    print $"  ($claude)"
  }
}
