{
  config,
  inputs,
  pkgs,
  ...
}:

let
  package = pkgs.github-copilot-cli.overrideAttrs (_: rec {
    version = "1.0.73";
    src = pkgs.fetchurl {
      url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-linux-x64.tar.gz";
      hash = "sha256:8f9bb5f7e364c267265d1e24ac2aea69ed559ddb956719c6db12a353de6c5970";
    };
    sourceRoot = ".";
    installPhase = ''
      runHook preInstall
      install -Dm755 copilot "$out/bin/copilot"
      runHook postInstall
    '';
    postInstall = "";
  });
in
{
  imports = [
    ./common.nix
    inputs.agent-skills.homeManagerModules.default
  ];

  programs.github-copilot-cli = {
    enable = true;
    inherit package;
    enableMcpIntegration = true;
    agents.trunk-triage = ../../../copilot/agents/trunk-triage.md;
    skills.trunk-based-jj = ../../../copilot/skills/trunk-based-jj;
    settings.notifications = true;
    skills.github-pr-checks = ../../../copilot/skills/github-pr-checks;
  };

  programs.agent-skills = {
    enable = true;
    sources.marimo-pair = {
      input = "marimo-pair";
      subdir = "skills";
    };
    sources.marimo-team = {
      input = "marimo-skills";
      subdir = "skills";
    };
    sources.anthropic = {
      input = "anthropic-skills";
      subdir = "skills";
    };
    sources.meta-quest = {
      input = "meta-quest-agentic-tools";
      subdir = "skills";
    };
    skills.enable = [
      "pdf"
      "marimo-pair"
      "anywidget"
      "hz-iwsdk-webxr"
    ];
    targets.copilot.enable = true;
  };

  dotfiles.tooling = {
    ai.copilot = {
      command = "${package}/bin/copilot";
      automation = ''
        ^${package}/bin/copilot --prompt $prompt --allow-all
      '';
    };
    checks.copilot-config =
      let
        homeFiles = config.home.file;
        copilotConfig = homeFiles."/home/schlich/.copilot/config.json".source;
        skill = homeFiles."/home/schlich/.copilot/skills/github-pr-checks".source;
      in
      pkgs.runCommand "copilot-config-check"
        {
          nativeBuildInputs = [ pkgs.jq ];
        }
        ''
          jq --exit-status '.notifications == true' ${copilotConfig}
          grep --fixed-strings --line-regexp 'name: github-pr-checks' ${skill}/SKILL.md
          grep --fixed-strings --line-regexp 'gh pr checks --required --watch --fail-fast' ${skill}/SKILL.md
          touch "$out"
        '';
  };
}
