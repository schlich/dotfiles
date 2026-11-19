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
    ../shared/common.nix
  ];

  programs.github-copilot-cli = {
    enable = true;
    inherit package;
    enableMcpIntegration = true;
    mcpServers.chrome-devtools = import ../mcp/chrome-devtools-mcp.nix // {
      type = "local";
      tools = [ "*" ];
    };
    agents.trunk-triage = ../../../../copilot/plugins/jj-flake-vigilance/agents/trunk-triage.agent.md;
    # No `settings`: Copilot rewrites config.json as runtime state and keeps
    # user preferences such as notifications in its own settings.json.
    skills = import ../shared/shared-skills.nix { inherit inputs; };
  };

  dotfiles.tooling.ai.copilot = {
    command = "${package}/bin/copilot";
    automation = ''
      ^${package}/bin/copilot --prompt $prompt --allow-all
    '';
  };
}
