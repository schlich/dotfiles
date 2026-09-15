{
  pkgs,
  config,
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
  programs.git = {
    enable = true;
    userName = config.accounts.email.accounts.personal.userName;
    userEmail = config.accounts.email.accounts.personal.address;
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
  ];
}
