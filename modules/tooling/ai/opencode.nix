{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  programs.opencode = {
    enable = true;
    package = pkgs.nuenv.writeScriptBin {
      name = "opencode";
      script = ''
        def --wrapped main [...args] {
          let github_token = (do -i { ^${pkgs.gh}/bin/gh auth token | str trim } | default "")

          if ($github_token | is-empty) {
            ^${pkgs.opencode}/bin/opencode ...$args
          } else {
            with-env { GITHUB_TOKEN: $github_token } {
              ^${pkgs.opencode}/bin/opencode ...$args
            }
          }
        }
      '';
    };
    enableMcpIntegration = true;
    skills = {
      immersive-songwriting-studio = ../../../copilot/skills/immersive-songwriting-studio;
      gh-stack = "${inputs.gh-stack}/skills/gh-stack";
      jj = ../../../copilot/skills/jj;
      trunk-based-jj = ../../../copilot/skills/trunk-based-jj;
      marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
      nu = ../../../copilot/skills/nushell;
      hz-immersive-designer = "${inputs.meta-quest-agentic-tools}/skills/hz-immersive-designer";
      hz-iwsdk-webxr = "${inputs.meta-quest-agentic-tools}/skills/hz-iwsdk-webxr";
      hz-new-project-creation = "${inputs.meta-quest-agentic-tools}/skills/hz-new-project-creation";
      hz-quest-verify-first = "${inputs.meta-quest-agentic-tools}/skills/hz-quest-verify-first";
      hz-store-pwa = "${inputs.meta-quest-agentic-tools}/skills/hz-store-pwa";
      hz-vr-debug = "${inputs.meta-quest-agentic-tools}/skills/hz-vr-debug";
      metavr-cli = "${inputs.meta-quest-agentic-tools}/skills/metavr-cli";
    };
    agents = ../../../copilot/agents;
    settings = {
      command.init-repo = {
        description = "Initialize the current directory as a Nix, Nushell, and Jujutsu project.";
        agent = "build";
        template = ''
          Initialize a new repository in the current directory. The project requirements are:

          - Use Nix as the default environment and package-management tool. Create a flake and development shell appropriate to the project requirements.
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
      ^${config.programs.opencode.package}/bin/opencode run --agent $agent --auto $prompt
    '';
  };
}
