{ inputs, pkgs, ... }:

let
  skills = import ./shared-skills.nix { inherit inputs; };
  codex = pkgs.writeNuScriptBin "codex" ''
    def --wrapped main [...args] {
      ^secretspec run --file ${../../secretspec.toml} --provider keyring -- ${pkgs.codex}/bin/codex ...$args
    }
  '';
in

{
  imports = [ ./common.nix ];

  programs.codex = {
    enable = true;
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
