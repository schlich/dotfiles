# nixpkgs-watch: jj-scripts
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
  wrapWithConfig = import ../../../lib/wrap-with-config.nix { inherit lib pkgs; };
  ssh = import ../ssh/ssh-client.nix { inherit lib pkgs; };

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
  # jj ai-describe, pinned to an upstream revision that includes its own
  # prompt engine.
  jjAiDescribe =
    let
      rev = "3c4a0ceb7e45afe81cb09996a6d5760a07f182bf";
      fetchScript =
        name: hash:
        pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/osteele/jj-scripts/${rev}/${name}";
          inherit hash;
        };
      describe = fetchScript "jj-ai-describe" "sha256-pDrq6bla8O+D24gjpkExFtn4r7+t9u79wLikDBIzYwU=";
      shared = fetchScript "jj-ai-lib.sh" "sha256-4E4H15UQcAO34Js0SGepI4RKSQ4uYU+054wyZCxG/II=";
      scripts = pkgs.runCommand "jj-ai-describe-scripts" { } ''
        mkdir -p "$out"
        cp ${describe} "$out/jj-ai-describe"
        cp ${shared} "$out/jj-ai-lib.sh"
      '';
    in
    pkgs.writeShellApplication {
      name = "jj-ai-describe";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.llm
        pkgs.python3
      ];
      text = ''
        exec ${pkgs.bash}/bin/bash ${scripts}/jj-ai-describe "$@"
      '';
    };
  # Plans, checks, and normalizes change graphs (tools/jj-graph/README.md).
  jjGraph = (import ../../../tools/jj-graph { inherit lib pkgs; }).package;
  # dotfiles' delivery: luvus/integration to main once its risk verdict
  # allows it and nixbot passes on it.
  luvusDeliver = pkgs.writeNuScriptBin "luvus-deliver" (
    builtins.replaceStrings [ "@reach@" ] [ "${../../../tools/den-reach.nix}" ] (
      builtins.readFile ../../../tools/luvus-deliver.nu
    )
  );
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
    # A branch deleted on the remote goes here too, so the list of remote
    # branches holds only what is still open (github:schlich/honeycomb).
    fetch.prune = true;
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
    ui.merge-editor = "kdiff3";
    merge-tools.kdiff3.program = lib.getExe pkgs.kdiff3;
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
    # The open topics: every head that trunk does not hold yet. At most six
    # at a time (github:schlich/honeycomb); `jj topics` lists them.
    revset-aliases."topics()" = "visible_heads() ~ ::trunk()";
    aliases.topics = [
      "log"
      "-r"
      "topics()"
    ];
    # `jj graph check`, `jj graph normalize`, and the rest of jj-graph's
    # commands, run against the repository jj is in.
    aliases.graph = [
      "util"
      "exec"
      "--"
      (lib.getExe jjGraph)
    ];
    aliases.ai-describe = [
      "util"
      "exec"
      "--"
      (lib.getExe jjAiDescribe)
    ];
    # GitHub (origin) holds dotfiles' trunk and topics. Elsewhere jj keeps
    # its own remote defaults; a global trunk() broke every repository
    # without that remote.
    "--scope" = [
      {
        "--when".repositories = [ config.dotfiles.paths.dotfiles ];
        git.push = "origin";
        git.fetch = "origin";
        revset-aliases."trunk()" = "main@origin";
      }
    ];
  };

  home.packages = [
    git
    jj
    jjGraph
    jjAiDescribe
    pkgs.llm
    pkgs.oyui
    ci.jj-describe
    config.dotfiles.ci.package
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../../jj/dashboard.nu))
    ci.context-status
    luvusDeliver
  ];

  dotfiles.retiredHomeFiles = [
    ".config/git/config"
    ".config/git/attributes"
    ".config/jj/config.toml"
  ];

  dotfiles.nixpkgsWatch.jj-scripts = {
    version = "0-unstable-2026-03-15";
    reason = "Replace the pinned jj-ai-describe scripts with the nixpkgs package once available.";
    repo = "osteele/jj-scripts";
  };

  dotfiles.nushellAutoload = {
    ci = ciNushell.completions;
    # Refuses an interactive `jj new` that would strand a `ci` topic.
    jj-guard = ciNushell.guard;
    # `jw NAME` changes to a JJ workspace's root.
    jj-workspace = ciNushell.workspace;
  };
}
