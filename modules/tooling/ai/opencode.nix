{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  agentSource = ../../../copilot/plugins/jj-flake-vigilance/agents;
  skills = import ./shared-skills.nix { inherit inputs; };
  adaptAgentTools =
    replacement: file:
    lib.concatMapStringsSep "\n" (line: if lib.hasPrefix "tools:" line then replacement else line) (
      lib.splitString "\n" (builtins.readFile file)
    );
in
{
  imports = [ ./common.nix ];

  xdg.configFile = lib.mapAttrs' (
    _: plugin: lib.nameValuePair "opencode/plugins/${plugin.target}" { source = plugin.source; }
  ) config.dotfiles.tooling.opencodeConfig;

  programs.opencode = {
    enable = true;
    package = pkgs.writeNuScriptBin "opencode" ''
      def --wrapped main [...args] {
        ^${pkgs.secretspec}/bin/secretspec run --file ${../../secretspec.toml} --provider keyring --profile default --reason "OpenCode invocation" -- ${pkgs.opencode}/bin/opencode ...$args
      }
    '';
    enableMcpIntegration = true;
    inherit skills;
    # Copilot agents declare tools as a list, while OpenCode expects a boolean
    # map. Adapt only the copies installed in OpenCode's config.
    agents = {
      project-specialist = adaptAgentTools "" "${agentSource}/project-specialist.agent.md";
      trunk-triage = adaptAgentTools "tools: { bash: false, edit: false, write: false, patch: false, task: false }" "${agentSource}/trunk-triage.agent.md";
    };
    settings = {
      command.init-repo = {
        description = "Initialize the current directory as a Nix, Nushell, and Jujutsu project.";
        agent = "build";
        template = ''
          Initialize a new repository in the current directory. The project requirements are:

          - Use Nix as the default environment and package-management tool. Create a flake and development shell targeting only x86_64-linux for all flake outputs unless explicitly asked for more.
          - Use Nushell for project scripts and automation rather than Bash where shell tooling is needed.
          - Use Jujutsu as the version-control interface, initialized with a Git backend for interoperability.
          - Add only the minimal repository metadata, ignores, and documentation needed for the chosen project shape.

          First inspect the directory and any supplied requirements. Do not overwrite or discard existing work. Ask one concise question only if the language, application type, or another material project decision is genuinely ambiguous.

          User requirements: $ARGUMENTS
        '';
      };
      mcp.github = {
        type = "remote";
        url = "https://api.githubcopilot.com/mcp/";
        enabled = true;
        oauth = false;
        headers.Authorization = "Bearer {env:GITHUB_TOKEN}";
      };
      server.hostname = "localhost";
    };
  };

  dotfiles.tooling.ai.opencode = {
    command = "${config.programs.opencode.package}/bin/opencode";
    automation = ''
      let model = $env.AI_RUN_MODEL?
      if $model == null {
        ^${config.programs.opencode.package}/bin/opencode run --agent $agent --auto $prompt
      } else {
        ^${config.programs.opencode.package}/bin/opencode run --agent $agent --model $model --auto $prompt
      }
    '';
  };
}
