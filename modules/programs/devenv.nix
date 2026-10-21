{
  lib,
  pkgs,
  ...
}:

# devenv reads its user configuration, the TUI and shell preferences, from the
# file DEVENV_USER_CONFIG names, so the wrapper points it at a store file
# rather than linking ~/.config/devenv/config.yaml. `devenv user-config show`
# prints the effective result. Project settings stay in each project's
# devenv.yaml; the cache is trusted in modules/nixos/devenv-cache.nix, and
# `devenv shell` already starts Nushell, the login shell.
let
  yamlFormat = pkgs.formats.yaml { };

  # Every TUI view leads its status line with its mode, NORMAL being the base
  # mode's name in every tool, then any pending key sequence and the keys
  # that work there.
  mode = text: {
    type = "text";
    inherit text;
    required = true;
    style.modifiers = [ "bold" ];
  };
  layout = name: left: {
    left = [ "mode-${name}" ] ++ left;
    center = [ ];
    right = [
      "pending_key"
      "key_hints"
    ];
  };

  userConfig = yamlFormat.generate "devenv-config.yaml" {
    version = 1;
    tui = {
      # Follow Ghostty's palette, as Luvus does.
      theme.preset = "terminal";
      statusline = {
        enabled = true;
        layouts = {
          main = layout "main" [ "summary" ];
          logs = layout "logs" [
            "log_mode"
            "log_position"
          ];
          search = layout "search" [ "search" ];
          prompt = layout "prompt" [ "prompt" ];
        };
        components = {
          mode-main = mode "NORMAL";
          mode-logs = mode "LOGS";
          mode-search = mode "SEARCH";
          mode-prompt = mode "PROMPT";
        };
      };
      behavior = {
        mouse = true;
        follow_logs = true;
      };
    };
  };

  devenv = import ../../lib/wrap-with-config.nix { inherit lib pkgs; } {
    package = pkgs.devenv;
    env.DEVENV_USER_CONFIG = "${userConfig}";
    # devenv ships secretspec beside itself; the repository's own copy in
    # modules/home/packages.nix is the one on PATH.
    postBuild = ''
      rm "$out/bin/secretspec"
    '';
  };
in
{
  # Ahead of the plain devenv in modules/home/packages.nix.
  home.packages = [ (lib.hiPrio devenv) ];

  dotfiles.retiredHomeFiles = [ ".config/devenv/config.yaml" ];

  # Fails the build when devenv rejects the file, such as an unknown key.
  dotfiles.tooling.checks.devenv-user-config =
    pkgs.runCommand "devenv-user-config-check" { nativeBuildInputs = [ pkgs.devenv ]; }
      ''
        HOME=$TMPDIR devenv user-config validate --user-config ${userConfig}
        touch $out
      '';
}
