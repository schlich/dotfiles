{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# Rex, the terminal multiplexer, from its prebuilt snapshot flake: the rex
# command, its xterm-rex terminfo entry in ~/.terminfo, and a personal server
# as the `rex` systemd user service. `loginctl enable-linger` keeps the
# server running while logged out.
#
# Rex has no interactive client for Linux yet; Rex.app on macOS is the only
# one released. Here `rex` is the command-line client, and `-S LABEL` sends a
# command to one of the hosts below instead of this machine's server.
let
  cfg = config.dotfiles.rex;
  rex = lib.getExe config.programs.rex.package;
  jq = lib.getExe pkgs.jq;
in
{
  imports = [ inputs.rex.homeManagerModules.default ];

  options.dotfiles.rex.hosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      homelab = "https://homelab.example.ts.net:7297";
    };
    description = ''
      Other Rex servers to reach by label, as in `rex -S homelab ls`. Rex
      keeps hosts as runtime state on the account's home server, so
      activation adds each missing label there and leaves an existing one
      alone, and `rex hosts edit` keeps working.
    '';
  };

  config = {
    programs.rex = {
      enable = true;
      # The guard needs Home Manager's programs.ssh, which this repository does
      # not use; ssh.nix includes it in the wrapped ssh's config instead.
      sshGuard = false;
    };
    services.rex.enable = true;

    # After the switch's own units start, so the server is normally up; when
    # it is not, the hosts wait for the next activation.
    home.activation.rexHosts = lib.mkIf (cfg.hosts != { }) (
      lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        if known=$(${rex} --autostart=false hosts list --json 2>/dev/null); then
          for entry in ${
            lib.escapeShellArgs (lib.mapAttrsToList (label: endpoint: "${label}=${endpoint}") cfg.hosts)
          }; do
            label=''${entry%%=*}
            endpoint=''${entry#*=}
            if ! ${jq} --exit-status --arg label "$label" \
              'any(.hosts[]; .host.label | ascii_downcase == ($label | ascii_downcase))' \
              <<<"$known" >/dev/null; then
              run ${rex} --autostart=false hosts add "$label" "$endpoint" \
                || warnEcho "rex: could not add host $label ($endpoint)"
            fi
          done
        else
          warnEcho "rex: the Rex server is not running, so hosts were not added: ${lib.concatStringsSep ", " (lib.attrNames cfg.hosts)}"
        fi
      ''
    );

    dotfiles.nixpkgsWatchExempt.rex = "the vendor's prebuilt, closed-source release; nixpkgs' rex is an unrelated Perl tool";
  };
}
