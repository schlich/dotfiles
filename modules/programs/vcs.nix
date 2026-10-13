{
  pkgs,
  config,
  inputs,
  ...
}:

let
  # The ci workflow and its companions come from the ci input.
  ci = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system};
  ciNushell = inputs.ci.lib.nushell;
in
{
  programs.git = {
    enable = true;
    settings.user = {
      name = config.accounts.email.accounts.personal.userName;
      email = config.accounts.email.accounts.personal.address;
    };
    # Claude Desktop runs sessions in a user namespace where Nix-store files
    # appear owned by `nobody`, so ssh refuses the Home Manager ~/.ssh/config
    # ("Bad owner or permissions") and every fetch or push to Tangled fails.
    # Naming the file with -F skips only that ownership check; ssh reads the
    # same configuration everywhere. jj fetches and pushes through git.
    settings.core.sshCommand = "ssh -F ${config.home.homeDirectory}/.ssh/config";
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
      # Tangled hosts trunk; GitHub (origin) is only a mirror that `ci land` updates.
      git.push = "tangled";
      git.fetch = [
        "tangled"
        "origin"
      ];
      revset-aliases."trunk()" = "main@tangled";
      git.executable-path = "${pkgs.git}/bin/git";
    };
  };

  home.packages = [
    ci.jj-describe
    ci.ci
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../jj/dashboard.nu))
    ci.context-status
  ];

  xdg.configFile."nushell/autoload/ci.nu".source = ciNushell.completions;
  # Refuses an interactive `jj new` that would strand a `ci` topic.
  xdg.configFile."nushell/autoload/jj-guard.nu".source = ciNushell.guard;
  # `jw NAME` changes to a JJ workspace's root.
  xdg.configFile."nushell/autoload/jj-workspace.nu".source = ciNushell.workspace;
}
