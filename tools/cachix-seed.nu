# Push this machine's builds of the flake checks to Cachix, so GitHub Actions
# downloads them instead of compiling them. Only paths already in the local
# store are pushed, and only those cache.nixos.org lacks: the cache holds what
# this flake builds itself, such as cross.stream, not a copy of nixpkgs.
def main [
  --flake: string = ""        # Flake to read the checks from (default: ~/dotfiles)
  --cache: string = "schlich" # Cachix cache to push to
  --remote                    # Also push the remoteChecks, the system closures
  --dry-run                   # List what would be pushed without pushing
  # The cache is public, so it must not redistribute unfree packages, which
  # cache.nixos.org lacks for that reason.
  --exclude: list<string> = [claude-code]
] {
  let flake = if $flake == "" { $"path:($env.HOME)/dotfiles" } else { $flake }
  let sets = if $remote { [checks remoteChecks] } else { [checks] }

  # A check's output is often only a marker file, so what a runner needs is
  # what building it takes: every output in its derivations' closure.
  let drvs = $sets | each {|set|
    ^nix eval --json $"($flake)#($set).x86_64-linux" --apply 'cs: builtins.mapAttrs (n: c: c.drvPath) cs'
    | from json
    | values
  } | flatten
  let closure = ^nix-store --query --requisites --include-outputs ...$drvs
    | lines
    | where {|p| not ($p | str ends-with ".drv") and ($p | path exists) }
  print $"($closure | length) outputs needed to build ($drvs | length) checks are in the local store."
  if ($closure | is-empty) { return }

  let upstream = ^nix path-info --json --json-format 1 --store https://cache.nixos.org ...$closure
    | from json
    | transpose path info
    | where info != null
    | get path
  let missing = $closure | where {|p|
    let name = $p | path basename | str substring 33..
    $p not-in $upstream and ($exclude | all {|e| not ($name | str starts-with $e) })
  }
  let size = if ($missing | is-empty) { 0b } else {
    ^nix path-info --json --json-format 1 ...$missing
    | from json
    | values
    | get narSize
    | math sum
    | into filesize
  }
  print $"($missing | length) of them need pushing: not on cache.nixos.org, not excluded \(($size) unpacked\)."

  if $dry_run {
    $missing
  } else if ($missing | is-not-empty) {
    $missing | str join "\n" | ^cachix push $cache
  }
}
