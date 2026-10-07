{ config, pkgs, ... }:

let
  unit = "nixos-switch-main";
  stateDir = "/var/lib/${unit}";
  host = config.networking.hostName;
  # Only `ci land` moves main, after building every flake check, so this
  # never applies a working copy or an unchecked change.
  repo = "https://tangled.org/schlich.tngl.sh/dotfiles";

  # Servers lack the nushellWith overlay behind writeNuScriptBin.
  switchMain = pkgs.writers.writeNuBin unit ''
    # Switch this host to the NixOS configuration on Tangled's main, giving
    # each distinct closure a stable, recognizable boot label.
    def main [] {
      let rev = (^git ls-remote "${repo}" refs/heads/main | lines | first | split row "\t" | first | str trim)
      if ($rev | is-empty) {
        error make { msg: "Could not resolve main on ${repo}." }
      }
      let flake = $"git+${repo}?ref=main&rev=($rev)"
      let system = $"($flake)#nixosConfigurations.${host}.config.system"
      print $"Switching ${host} to main at ($rev | str substring 0..11)."

      let base_path = (^env -u NIXOS_LABEL nix eval --raw --impure $"($system).build.toplevel.outPath" | str trim)
      let base_label = (^env -u NIXOS_LABEL nix eval --raw --impure $"($system).nixos.label" | str trim)
      let fingerprint = ($base_path | path basename | split row "-" | first)
      let label = $"($base_label)-($fingerprint)"
      let candidate = (^env $"NIXOS_LABEL=($label)" nix eval --raw --impure $"($system).build.toplevel.outPath" | str trim)
      let active = (^readlink --canonicalize /run/current-system | str trim)
      let state = { rev: $rev, toplevel: $candidate, label: $label, at: (date now | format date "%+") }

      if $candidate == $active {
        print "That configuration is already active; no generation created."
        $state | insert exit_code 0 | to nuon | save --force "${stateDir}/last.nuon"
        return
      }

      # Build the exact closure gently, preview what activation will change,
      # then switch to that store path.
      let code = (try {
        print "Free space on /nix:"
        ^df -h /nix
        print "Building the closure with one job and two cores..."
        ^env $"NIXOS_LABEL=($label)" nix build --no-link --impure --max-jobs 1 --cores 2 $"($system).build.toplevel"
        print $"Built ($candidate). Previewing service changes..."
        ^nixos-rebuild dry-activate --store-path $candidate
        ^nixos-rebuild switch --store-path $candidate
        0
      } catch {
        $env.LAST_EXIT_CODE? | default 1
      })
      $state | insert exit_code $code | to nuon | save --force "${stateDir}/last.nuon"
      if $code != 0 {
        exit $code
      }
    }
  '';
in

{
  # Apply landed main without sudo: the system-switch command starts this
  # unit over D-Bus, which also works where sudo cannot, such as inside the
  # Claude desktop app's sandbox.
  systemd.services.${unit} = {
    description = "Switch to the NixOS configuration on Tangled's main";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [
      config.nix.package
      config.system.build.nixos-rebuild
      pkgs.coreutils
      pkgs.git
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${switchMain}/bin/${unit}";
      StateDirectory = unit;
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  # schlich may start that one unit from an active local session without a
  # password. Stopping, editing, or starting any other unit still asks.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "${unit}.service" &&
          action.lookup("verb") == "start" &&
          subject.user == "schlich" &&
          subject.local && subject.active) {
        return polkit.Result.YES;
      }
    });
  '';
}
