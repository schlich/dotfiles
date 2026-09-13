{
  pkgs,
  ...
}:

let
  jjCiScript = pkgs.writeNuScriptBin "jj-ci" (builtins.readFile ../../jj/ci.nu);
  jjCi = pkgs.symlinkJoin {
    name = "jj-ci";
    paths = [ jjCiScript ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/jj-ci" --prefix PATH : ${pkgs.git}/bin
    '';
  };
in
{
  programs.git.enable = false;
  programs.gpg.enable = true;
  programs.lazygit.enable = false;
  # JJ invokes Git for transport; the executable is an explicit dependency,
  # while authentication remains available without Home Manager's Git module.
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
  ];
}
