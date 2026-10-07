{
  config,
  inputs,
  pkgs,
  ...
}:

let
  skills = import ./shared-skills.nix { inherit inputs; };
  # Codex Desktop writes to $CODEX_HOME/config.toml. Keep static settings on
  # the executable instead of letting Home Manager manage that mutable file.
  codex = pkgs.writeNuScriptBin "codex" ''
    def --wrapped main [...args] {
      mut workspace = ""
      if ($args | is-empty) {
        let root_result = (^jj root | complete)
        if $root_result.exit_code == 0 {
          let root = ($root_result.stdout | str trim)
          if ($root | path join "jj" "ci.nu" | path exists) {
            let listing = (^jj --repository $root workspace list -T 'name ++ "\t" ++ target.current_working_copy() ++ "\n"' | complete)
            if $listing.exit_code == 0 and ($listing.stdout | lines | any {|line| $line == "default\ttrue" }) {
              let name = $"codex-(date now | format date '%Y%m%d-%H%M%S')-(random int 100000..999999)"
              let started = (do { cd $root; ^ci start $name } | complete)
              if $started.exit_code != 0 {
                error make { msg: $"Could not start Codex workspace: ($started.stderr | str trim)" }
              }
              $workspace = ($"($root)/.jj-workspaces/($name)")
            }
          }
        }
      }
      let directory_args = if $workspace == "" { [] } else { ["-C" $workspace] }
      ^${pkgs.secretspec}/bin/secretspec run --file ${../../secretspec.toml} --provider keyring --profile default --reason "Codex invocation" -- ${pkgs.codex}/bin/codex ...$directory_args --config 'desktop.git-pr-watch-auto-merge=false' --config 'desktop.custom_file_handlers.jj-dashboard={label = "JJ dashboard", command = "jj-dashboard", icon = "${../../../jj/icon.svg}", input = "path", supports_ssh = false}' ...$args
    }
  '';
in

{
  imports = [ ./common.nix ];

  programs.codex = {
    enable = true;
    package = codex;
    inherit skills;
    context = ./global-agent-instructions.md;
  };

  programs.codexDesktopLinux = {
    enable = config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "codex";
    # The desktop launcher must use the same configured wrapper as the CLI.
    cliPackage = codex;
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
