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
      # then switch to that store path. --no-reexec keeps nixos-rebuild from
      # rebuilding itself through <nixpkgs/nixos>, which needs a nixos-config
      # NIX_PATH entry this unit lacks; the unit's path already pins it.
      let code = (try {
        print "Free space on /nix:"
        ^df -h /nix
        print "Building the closure with one job and two cores..."
        ^env $"NIXOS_LABEL=($label)" nix build --no-link --impure --max-jobs 1 --cores 2 $"($system).build.toplevel"
        print $"Built ($candidate). Previewing service changes..."
        ^nixos-rebuild dry-activate --no-reexec --store-path $candidate
        ^nixos-rebuild switch --no-reexec --store-path $candidate
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

  # Start the unit and show its output and result. The journal is read
  # through the user manager so this also works inside the Claude desktop
  # app's sandbox. It lives here, not in Home Manager, so hosts without Home
  # Manager (homelab) get it too.
  systemSwitch = pkgs.writers.writeNuBin "system-switch" ''
    # Apply the NixOS configuration on Tangled's main without sudo: start
    # the root ${unit} unit, then show its output and result.
    def main [] {
      let unit = "${unit}.service"
      let bin = "/run/current-system/sw/bin"
      let since = (date now | format date "%Y-%m-%d %H:%M:%S")
      print $"Switching to main through ($unit)..."
      let result = (^$"($bin)/systemctl" start $unit | complete)
      let log = (
        ^$"($bin)/systemd-run" --user --pipe --wait --collect --quiet
          $"($bin)/journalctl" --unit $unit --since $since --no-pager --output cat
        | complete
      )
      print $log.stdout
      let state = "${stateDir}/last.nuon"
      if ($state | path exists) {
        print (open $state)
      }
      let failed = (^$"($bin)/systemctl" --failed --no-legend --plain | complete | get stdout | str trim)
      if ($failed | is-not-empty) {
        print $"Failed units:\n($failed)"
      }
      if $result.exit_code != 0 {
        error make { msg: $"($unit) failed: ($result.stderr | str trim)" }
      }
    }
  '';
in

{
  environment.systemPackages = [ systemSwitch ];

  # Apply landed main without sudo: the system-switch command starts this
  # unit over D-Bus, which also works where sudo cannot, such as inside the
  # Claude desktop app's sandbox.
  systemd.services.${unit} = {
    description = "Switch to the NixOS configuration on Tangled's main";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The switch runs inside this unit, so a configuration that changes it
    # must not stop it mid-switch: the new definition applies on the next run.
    restartIfChanged = false;
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

  # schlich may start that one unit from an active local session, and any
  # wheel member may start it from a remote session such as ssh to homelab,
  # without a password. Stopping, editing, or starting any other unit still
  # asks.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "${unit}.service" &&
          action.lookup("verb") == "start" &&
          ((subject.user == "schlich" && subject.local && subject.active) ||
           subject.isInGroup("wheel"))) {
        return polkit.Result.YES;
      }
    });
  '';
}
