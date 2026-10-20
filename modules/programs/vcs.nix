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
  # Plans, checks, and normalizes change graphs (tools/jj-graph/README.md).
  jjGraph = (import ../../tools/jj-graph { inherit lib pkgs; }).package;
in
{
  imports = [ ./ci.nix ];

  # Other modules reach the wrapped git and jj through these options.
  programs.git.package = git;
  programs.jujutsu.package = jj;
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
    ui.diff-editor = "oyui";
    ui.diff-instructions = false;
    merge-tools.oyui = {
      program = "oyui";
      edit-args = [
        "diff"
        "$left"
        "$right"
      ];
    };
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
    # `jj graph check`, `jj graph normalize`, and the rest of jj-graph's
    # commands, run against the repository jj is in.
    aliases.graph = [
      "util"
      "exec"
      "--"
      (lib.getExe jjGraph)
    ];
    # GitHub (origin) holds dotfiles' trunk and topics; Tangled only mirrors
    # main, which `ci land` pushes there itself. Tangled still holds the ci
    # repository's trunk, with GitHub as its mirror. Elsewhere jj keeps its
    # own remote defaults; a global main@tangled broke every repository
    # without one. New repositories hosted on Tangled get their settings in
    # their own config from `tangled-init`.
    "--scope" = [
      {
        "--when".repositories = [ "~/dotfiles" ];
        git.push = "origin";
        git.fetch = "origin";
        revset-aliases."trunk()" = "main@origin";
      }
      {
        "--when".repositories = [ "~/Projects/ci" ];
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
    jjGraph
    pkgs.oyui
    ci.jj-describe
    config.dotfiles.ci.package
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../jj/dashboard.nu))
    (pkgs.writeNuScriptBin "tangled-init" (builtins.readFile ../../jj/tangled-init.nu))
    ci.context-status
    # dotfiles' delivery: luvus/integration to main once nix-ci passes on it.
    (pkgs.writeNuScriptBin "luvus-deliver" (builtins.readFile ../../tools/luvus-deliver.nu))
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
