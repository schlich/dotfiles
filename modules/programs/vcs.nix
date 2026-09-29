{
  pkgs,
  config,
  ...
}:

let
  jjCiScript = pkgs.writeNuScriptBin "ci" (builtins.readFile ../../jj/ci.nu);
  jjCi = pkgs.symlinkJoin {
    name = "ci";
    paths = [ jjCiScript ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/ci" --prefix PATH : ${pkgs.git}/bin:${pkgs.gh}/bin \
        --set JJ_CI_SOURCE_SHA256 ${builtins.hashFile "sha256" ../../jj/ci.nu}
      # Deprecated alias for the former `jj-ci` name.
      ln -s ci "$out/bin/jj-ci"
    '';
  };
in
{
  programs.git = {
    enable = true;
    settings.user = {
      name = config.accounts.email.accounts.personal.userName;
      email = config.accounts.email.accounts.personal.address;
    };
  };
  programs.gpg.enable = true;
  programs.lazygit.enable = false;
  xdg.configFile."git/config".text = ''
    [credential "https://github.com"]
      helper =
      helper = !${pkgs.gh}/bin/gh auth git-credential
    [credential "https://gist.github.com"]
      helper =
      helper = !${pkgs.gh}/bin/gh auth git-credential
  '';
  programs.jjui.enable = true;

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        email = "ty.schlich@gmail.com";
        name = "schlich";
      };
      ui.diff-formatter = [
        "difft"
        "--color=always"
        "$left"
        "$right"
      ];
      fix.tools.nixfmt = {
        command = [
          "nixfmt"
          "--filename=$path"
        ];
        patterns = [ "glob:'**/*.nix'" ];
      };
      fix.tools.ruff-format = {
        command = [
          "ruff"
          "format"
          "--stdin-filename=$path"
          "-"
        ];
        patterns = [ "glob:'**/*.py'" ];
      };
      git.push = "origin";
      git.fetch = "origin";
      git.executable-path = "${pkgs.git}/bin/git";
    };
  };

  home.packages = [
    (pkgs.writeNuScriptBin "jj-describe" (builtins.readFile ../../jj/describe.nu))
    jjCi
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../jj/dashboard.nu))
    (import ../../jj/context-status.nix { inherit pkgs; })
  ];

  xdg.configFile."nushell/autoload/ci.nu".source = ../../jj/completions.nu;
  # Refuses an interactive `jj new` that would strand a `ci` topic.
  xdg.configFile."nushell/autoload/jj-guard.nu".source = ../../jj/guard.nu;
  # `jw NAME` changes to a JJ workspace's root.
  xdg.configFile."nushell/autoload/jj-workspace.nu".source = ../../jj/workspace.nu;
}
