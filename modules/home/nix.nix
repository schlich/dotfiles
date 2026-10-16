{
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  closureDiff = lib.getExe (import ../../lib/closure-diff.nix { inherit lib pkgs; });
in
{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  accounts.email.accounts.personal = {
    address = "ty.schlich@gmail.com";
    primary = true;
    realName = "Ty Schlichenmeyer";
    userName = "schlich";
  };
  fonts.fontconfig.enable = true;
  home.packages = [
    # Deploys the flake's colmenaHive: `colmena apply --on homelab`. The
    # binary-cached release; the colmena input supplies only makeHive.
    pkgs.colmena
    (pkgs.writeNuScriptBin "nix-suite" ''
      # One entry point for Nix validation, builds, and dependency inspection.
      # A raw string, so the apostrophe in "flake's" does not end it.
      def usage [] {
        print r#'Usage: nix-suite <command> [args...]

      Validation and builds:
        check       Format-check, flake-check, and build Home Manager + NixOS
        build       Build an installable with nix-output-monitor (nom)
        nh          Run nh with the supplied arguments

      Dependency and store inspection:
        tree        Browse a derivation or store path with nix-tree
        du          Inspect store usage with nix-du
        deps        Extract a flake dependency graph with nixtract
        treemap     Run nix-deps-treemap from its flake
        topology    Build this flake's nix-topology output

      Package changes (dix):
        diff        From the running system to this checkout's system; from the
                    running system to one closure; or between two closures.
                    Each may be a store path or an installable to build.
        last [N]    Across the N newest system generations (default 1)

      Examples:
        nix-suite check
        nix-suite build path:.#nixosConfigurations.asus.config.system.build.toplevel
        nix-suite tree path:/run/current-system/sw
        nix-suite du --root /run/current-system/sw
        nix-suite deps nixtract.jsonl
        nix-suite diff
        nix-suite diff /nix/var/nix/profiles/system-41-link /run/current-system
        nix-suite last 3
      '#
      }

      # A path as given; anything else is an installable to build first.
      def closure [target: string] {
        if ($target | path exists) {
          $target
        } else {
          print --stderr $"==> Building ($target)"
          ^nix build --no-link --print-out-paths $target | lines | last
        }
      }

      def package-changes [targets: list<string>] {
        let pair = match ($targets | length) {
          0 => ["/run/current-system" (closure "path:.#nixosConfigurations.${osConfig.networking.hostName}.config.system.build.toplevel")]
          1 => ["/run/current-system" (closure $targets.0)]
          2 => [(closure $targets.0) (closure $targets.1)]
          _ => { error make { msg: "diff takes at most two closures: OLD NEW" } }
        }
        ^${closureDiff} $pair.0 $pair.1
      }

      def system-generations [profiles: path = "/nix/var/nix/profiles"] {
        ls $profiles
        | where name =~ 'system-\d+-link$'
        | each {|link|
            {
              generation: ($link.name | parse --regex 'system-(?<n>\d+)-link$' | get 0.n | into int)
              path: $link.name
            }
          }
        | sort-by generation
      }

      def generation-changes [count: int] {
        let generations = (system-generations | last ($count + 1))
        if ($generations | length) < 2 {
          error make { msg: "Fewer than two system generations exist." }
        }
        for pair in ($generations | window 2) {
          print $"==> system generation ($pair.0.generation) -> ($pair.1.generation)"
          ^${closureDiff} $pair.0.path $pair.1.path
        }
      }

      def run-step [label: string, command: closure] {
        print $"==> ($label)"
        let result = (do $command | complete)
        if $result.exit_code != 0 {
          if not ($result.stderr | is-empty) { print -e $result.stderr }
          error make { msg: $"($label) failed with exit code ($result.exit_code)." }
        }
      }

      def check [] {
        run-step "Nix formatting" { ^nix fmt -- --check }
        run-step "Flake checks" { ^nix flake check path:. }
        run-step "Home Manager build" {
          ^nom build path:.#nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage
        }
        run-step "NixOS build" {
          ^nom build path:.#nixosConfigurations.asus.config.system.build.toplevel
        }
        print "Nix validation passed."
      }

      def --wrapped main [command?: string, ...args] {
        let command = ($command | default "help")
        match $command {
          "help" => (usage)
          "check" => (check)
          "build" => {
            if ($args | is-empty) {
              error make { msg: "build requires an installable, for example path:.#nixosConfigurations.asus.config.system.build.toplevel" }
            }
            ^nom build ...$args
          }
          "nh" => (^nh ...$args)
          "tree" => (^nix-tree ...$args)
          "du" => (^nix-du ...$args)
          "deps" => {
            ^nix run github:tweag/nixtract -- --target-flake-ref path:. --target-system x86_64-linux ...$args
          }
          "treemap" => (^nix run github:azeirah/nix-deps-treemap -- ...$args)
          "topology" => {
            ^nix build path:.#topology.x86_64-linux.config.output ...$args
          }
          "diff" => (package-changes $args)
          "last" => (generation-changes ($args | get --optional 0 | default 1 | into int))
          _ => {
            usage
            error make { msg: $"Unknown nix-suite command: ($command)" }
          }
        }
      }
    '')
    (pkgs.writeNuScriptBin "home-activate" ''
      # Build and activate the Home Manager configuration embedded in NixOS.
      def main [] {
        let flake = "path:/home/schlich/dotfiles#nixosConfigurations.${osConfig.networking.hostName}.config.home-manager.users.schlich.home.activationPackage"
        let activation = (^/run/current-system/sw/bin/nix build --no-link --print-out-paths $flake | str trim)

        if ($activation | is-empty) {
          error make { msg: "Nix did not produce a Home Manager activation package." }
        }

        run-external $"($activation)/activate" -- --driver-version 1
      }
    '')
  ];
}
