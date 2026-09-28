{
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
    agents.trunk-triage = ../../../copilot/plugins/jj-flake-vigilance/agents/trunk-triage.agent.md;
    # No `settings`: Copilot rewrites config.json as runtime state and keeps
    # user preferences such as notifications in its own settings.json.
    skills = import ./shared-skills.nix { inherit inputs; };
  };

  dotfiles.tooling.ai.copilot = {
    command = "${package}/bin/copilot";
    automation = ''
      ^${package}/bin/copilot --prompt $prompt --allow-all
    '';
  };
}
