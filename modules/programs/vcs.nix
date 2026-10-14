{
  pkgs,
  config,
  inputs,
  lib,
  ...
}:

let
  # The ci workflow and its companions come from the ci input.
  ci = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system};
  ciNushell = inputs.ci.lib.nushell;
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  ssh = import ./ssh-client.nix { inherit lib pkgs; };

  # programs.git and programs.jujutsu stay disabled: their options collect
  # settings from this and other modules (bun adds a lockb diff driver), and
  # the wrappers below carry the result instead of ~/.config.
  gitAttributes = pkgs.writeText "git-attributes" (lib.concatLines config.programs.git.attributes);
  git = wrapWithConfig {
    package = pkgs.git;
    env.GIT_CONFIG_GLOBAL = "${pkgs.writeText "gitconfig" (
      lib.generators.toGitINI config.programs.git.settings
    )}";
  };
  jj = wrapWithConfig {
    package = pkgs.jujutsu;
    env.JJ_CONFIG = "${(pkgs.formats.toml { }).generate "jj-config.toml"
      config.programs.jujutsu.settings
    }";
  };
in
{
  # Other modules reach the wrapped git through this option.
  programs.git.package = git;
  programs.git.settings = {
    user = {
      name = config.accounts.email.accounts.personal.userName;
      email = config.accounts.email.accounts.personal.address;
    };
    core = {
      sshCommand = lib.getExe' ssh "ssh";
      attributesFile = "${gitAttributes}";
    };
    credential = lib.genAttrs [ "https://github.com" "https://gist.github.com" ] (_: {
      helper = [
        ""
        "!${pkgs.gh}/bin/gh auth git-credential"
      ];
    });
  };
  programs.gpg.enable = true;
  programs.lazygit.enable = false;
  programs.jjui.enable = true;

  programs.jujutsu.settings = {
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
    ui.diff-editor = "meld";
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
    git.executable-path = lib.getExe git;
    # In the repositories Tangled hosts, it holds trunk and GitHub (origin) is
    # only a mirror that `ci land` updates. Elsewhere jj keeps its own remote
    # defaults; a global main@tangled broke every repository without one.
    # New repositories get the same settings in their own config from
    # `tangled-init`.
    "--scope" = [
      {
        "--when".repositories = [
          "~/dotfiles"
          "~/40-49 Nix tooling/ci"
        ];
        git.push = "tangled";
        git.fetch = [
          "tangled"
          "origin"
        ];
        revset-aliases."trunk()" = "main@tangled";
      }
    ];
  };

  home.packages = [
    git
    jj
    pkgs.meld
    ci.jj-describe
    ci.ci
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../jj/dashboard.nu))
    (pkgs.writeNuScriptBin "tangled-init" (builtins.readFile ../../jj/tangled-init.nu))
    ci.context-status
  ];

  dotfiles.retiredHomeFiles = [
    ".config/git/config"
    ".config/git/attributes"
    ".config/jj/config.toml"
  ];

  dotfiles.nushellAutoload = {
    ci = ciNushell.completions;
    # Refuses an interactive `jj new` that would strand a `ci` topic.
    jj-guard = ciNushell.guard;
    # `jw NAME` changes to a JJ workspace's root.
    jj-workspace = ciNushell.workspace;
    # `jj git init` of a repository without remotes runs `tangled-init`.
    jj-tangled-init = ../../jj/tangled-init-hook.nu;
  };
}
