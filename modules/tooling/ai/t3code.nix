{
  config,
  lib,
  pkgs,
  ...
}:

let
  # T3 Code drives the Claude Code and Codex CLIs, which sign in with the
  # Claude and ChatGPT subscriptions themselves. Leave both off the wrapper's
  # PATH so it finds the profile's configured `claude` and `codex` wrapper
  # rather than plain nixpkgs copies. The app sets its own Wayland app ID,
  # com.t3tools.T3Code, which niri's agents rules match.
  t3code = pkgs.t3code.override { enableCodex = false; };
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "t3code") {
  home.packages = [ t3code ];

  xdg.configFile."autostart/t3code.desktop".source = "${t3code}/share/applications/t3code.desktop";
}
