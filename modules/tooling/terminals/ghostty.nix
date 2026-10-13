{
  config,
  lib,
  pkgs,
  ...
}:

let
  wrapWithConfig = import ../../../lib/wrap-with-config.nix { inherit lib pkgs; };
  keyValue = pkgs.formats.keyValue {
    listsAsDuplicateKeys = true;
    mkKeyValue = lib.generators.mkKeyValueDefault { } " = ";
  };

  ghosttyConfig = keyValue.generate "ghostty-config" {
    copy-on-select = true;
    font-family = "Monaspace Krypton";
    # Splits and tabs replace Zellij panes and tabs, on the Alt keys Zellij
    # used; Niri columns and workspaces carry layouts and sessions. Alt+n/i/o
    # stay with Helix.
    keybind = [
      "alt+h=goto_split:left"
      "alt+left=goto_split:left"
      "alt+l=goto_split:right"
      "alt+right=goto_split:right"
      "alt+j=goto_split:down"
      "alt+down=goto_split:down"
      "alt+k=goto_split:up"
      "alt+up=goto_split:up"
      "alt+f=toggle_split_zoom"
      "alt+equal=equalize_splits"
      "alt+bracket_left=previous_tab"
      "alt+bracket_right=next_tab"
    ];
  };

  # Ghostty runs as one long-lived instance, so the wrapper names the copy in
  # the user profile, which a switch updates; Reload Configuration then picks
  # up the new file without restarting the instance.
  profileConfig = "etc/xdg/ghostty/config";
  ghostty = wrapWithConfig {
    package = pkgs.ghostty;
    flags = [
      "--config-default-files=false"
      "--config-file=${config.home.profileDirectory}/${profileConfig}"
    ];
    # D-Bus activation and the systemd unit start the unwrapped binary by
    # store path; the desktop file runs `ghostty` from PATH.
    postBuild = ''
      install -Dm444 ${ghosttyConfig} "$out/${profileConfig}"
      for file in share/systemd/user/app-com.mitchellh.ghostty.service share/dbus-1/services/com.mitchellh.ghostty.service; do
        rm "$out/$file"
        substitute ${pkgs.ghostty}/$file "$out/$file" \
          --replace-fail ${pkgs.ghostty}/bin/ghostty "$out/bin/ghostty"
      done
    '';
  };
in
{
  programs.ghostty = lib.mkIf (config.dotfiles.primary.terminal == "ghostty") {
    enable = true;
    package = ghostty;
    # bat's wrapper in modules/programs/cli.nix builds Ghostty's syntax into
    # its cache instead.
    installBatSyntax = false;
  };

  dotfiles.retiredHomeFiles = [ ".config/ghostty/config" ];
  dotfiles.tooling.checks.ghostty-config = pkgs.runCommandLocal "ghostty-config-check" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${lib.getExe pkgs.ghostty} +validate-config --config-file=${ghosttyConfig}
    touch "$out"
  '';

  # A command runs as given: Ghostty's shell integration rewrites a `nu -e ...`
  # command through /bin/sh, and the window exits at once.
  dotfiles.tooling.terminals.ghostty.launcher = ''
    let class_args = if ($class | is-empty) { [] } else { [$"--class=($class)"] }
    let command_args = if ($args | is-empty) { [] } else { ["--shell-integration=none" "-e"] ++ $args }
    ^${lib.getExe config.programs.ghostty.package} ...$class_args $"--working-directory=($directory)" ...$command_args
  '';
}
