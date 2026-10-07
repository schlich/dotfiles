{
  inputs,
  pkgs,
  ...
}:

let
  # llm-agents tracks Copilot releases daily and serves them from its cache.
  # Apply its overlay to this configuration's pkgs so allowUnfree holds.
  package = (inputs.llm-agents.overlays.shared-nixpkgs pkgs pkgs).llm-agents.copilot-cli;
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
