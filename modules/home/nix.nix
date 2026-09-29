{ pkgs, ... }:

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
    (pkgs.writeNuScriptBin "nix-suite" ''
      # One entry point for Nix validation, builds, and dependency inspection.
      def usage [] {
        print 'Usage: nix-suite <command> [args...]

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

      Examples:
        nix-suite check
        nix-suite build path:.#nixosConfigurations.asus.config.system.build.toplevel
        nix-suite tree path:/run/current-system/sw
        nix-suite du --root /run/current-system/sw
        nix-suite deps nixtract.jsonl
      '
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
          _ => {
            usage
            error make { msg: $"Unknown nix-suite command: ($command)" }
          }
        }
      }
    '')
    (pkgs.writeNuScriptBin "nixos-activate" ''
      # Give each distinct system closure a stable, recognizable boot label.
      def --wrapped main [...args] {
        let flake = "path:/home/schlich/dotfiles"
        let toplevel = $"($flake)#nixosConfigurations.asus.config.system.build.toplevel.outPath"
        let label_option = $"($flake)#nixosConfigurations.asus.config.system.nixos.label"
        let base_path = (
          ^env -u NIXOS_LABEL nix eval --raw --impure $toplevel
          | str trim
        )
        let base_label = (
          ^env -u NIXOS_LABEL nix eval --raw --impure $label_option
          | str trim
        )
        let fingerprint = ($base_path | path basename | split row "-" | first)
        let label = $"($base_label)-($fingerprint)"
        let candidate = (
          ^env $"NIXOS_LABEL=($label)" nix eval --raw --impure $toplevel
          | str trim
        )
        let active = (^readlink --canonicalize /run/current-system | str trim)

        if $candidate == $active {
          print "The candidate NixOS toplevel is already active; no generation created."
          return
        }

        ^sudo env $"NIXOS_LABEL=($label)" nixos-rebuild switch --flake "path:/home/schlich/dotfiles#asus" ...$args
      }
    '')
    (pkgs.writeNuScriptBin "home-activate" ''
      # Build and activate the Home Manager configuration embedded in NixOS.
      def main [] {
        let flake = "path:/home/schlich/dotfiles#nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage"
        let activation = (^/run/current-system/sw/bin/nix build --no-link --print-out-paths $flake | str trim)

        if ($activation | is-empty) {
          error make { msg: "Nix did not produce a Home Manager activation package." }
        }

        run-external $"($activation)/activate" -- --driver-version 1
      }
    '')
  ];
}
