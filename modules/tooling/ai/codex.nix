{
  inputs,
  pkgs,
  ...
}:

let
  skills = import ./shared-skills.nix { inherit inputs; };
  # Codex Desktop writes to $CODEX_HOME/config.toml. Home Manager merges these
  # defaults into the writable file during activation, preserving app settings.
  # The session hook claims a free workspace, the default checkout included,
  # so launching never creates one.
  codex =
    (pkgs.writeNuScriptBin "codex" ''
      def --wrapped main [...args] {
        ^${pkgs.secretspec}/bin/secretspec run --file ${../../secretspec.toml} --provider keyring --profile default --reason "Codex invocation" -- ${pkgs.codex}/bin/codex ...$args
      }
    '').overrideAttrs
      (_: {
        # Home Manager checks the package version before enabling mutable settings.
        version = pkgs.codex.version;
      });
in

{
  imports = [ ./common.nix ];

  programs.codex = {
    enable = true;
    package = codex;
    mutableSettings = true;
    settings = {
      desktop.git-pr-watch-auto-merge = false;
      desktop.custom_file_handlers."jj-dashboard" = {
        label = "JJ dashboard";
        command = "jj-dashboard";
        icon = "${../../../jj/icon.svg}";
        input = "path";
        supports_ssh = false;
      };
    };
    inherit skills;
    context = ./global-agent-instructions.md;
  };

  home.file = {
    ".codex/agents/jj-trunk-triage.toml".text = ''
      name = "jj_trunk_triage"
      description = "Lightweight read-only triage for JJ trunk status, PR checks, stack state, and formatting-only corrections."
      model = "gpt-5.6-luna"
      model_reasoning_effort = "medium"
      sandbox_mode = "read-only"
      developer_instructions = """
      Use this agent for read-only status, PR and CI summaries, stack inspection, and formatting-only corrections. Do not mutate JJ history, resolve conflicts, publish or merge pull requests, link or merge stacks, or make credentialed GitHub writes. Report actionable state to the parent agent.
      """
    '';
  };

  dotfiles.tooling.ai.codex = {
    command = "${codex}/bin/codex";
    automation = ''
      ^${codex}/bin/codex exec --dangerously-bypass-approvals-and-sandbox $prompt
    '';
  };
}
