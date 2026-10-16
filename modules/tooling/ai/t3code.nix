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
  # rather than plain nixpkgs copies. Electron derives the Wayland app ID from
  # CHROME_DESKTOP; naming the desktop entry makes it `t3code`, which niri's
  # agents rules match.
  t3code = pkgs.symlinkJoin {
    name = "t3code";
    paths = [ (pkgs.t3code.override { enableCodex = false; }) ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/t3code-desktop" --set-default CHROME_DESKTOP t3code.desktop
    '';
  };
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "t3code") {
  home.packages = [ t3code ];

  xdg.configFile."autostart/t3code.desktop".source = "${t3code}/share/applications/t3code.desktop";
}
