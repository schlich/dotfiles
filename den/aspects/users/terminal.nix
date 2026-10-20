{

  # Every Home Manager host: the Nushell configuration and the command-line
  # tools it hooks (Starship, Atuin, zoxide, carapace, direnv), git, jj, ssh.
  # interface.nix only declares the dotfiles.primary options here; its
  # launchers and checks need the desktop tooling below.
  den.aspects.user-shell.homeManager.imports = [
    ../../../modules/home
    ../../../modules/tooling/interface.nix
    ../../../modules/programs/cli.nix
    ../../../modules/programs/shell.nix
    ../../../modules/programs/ssh.nix
    ../../../modules/programs/vcs.nix
    ../../../modules/programs/yazi.nix
    # The Claude Code CLI with its skills, hooks and MCP servers.
    ../../../modules/tooling/ai/claude-code.nix
  ];

  # Workstations only: terminals, editors, agent clients, desktop apps and
  # the user services that go with them. modules/programs repeats the shell
  # files above, which the module system imports once.
  den.aspects.user-desktop.homeManager.imports = [
    ../../../modules/tooling/terminals/kitty.nix
    ../../../modules/tooling/terminals/ghostty.nix
    ../../../modules/tooling/editors/helix.nix
    ../../../modules/tooling/editors/zed.nix
    ../../../modules/tooling/keymap-checks.nix
    ../../../modules/tooling/knowledge/iwe.nix
    ../../../modules/tooling/ai/plugins.nix
    ../../../modules/tooling/ai/t3code.nix
    ../../../modules/tooling/ai/opencode.nix
    ../../../modules/tooling/ai/opencode-desktop.nix
    ../../../modules/tooling/ai/claude-desktop.nix
    ../../../modules/tooling/ai/codex.nix
    ../../../modules/tooling/ai/copilot.nix
    ../../../modules/home/files.nix
    ../../../modules/home/packages.nix
    ../../../modules/home/services.nix
    ../../../modules/programs
  ];
}
