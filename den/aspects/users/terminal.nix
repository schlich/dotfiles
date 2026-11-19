{

  # Every Home Manager host: the Nushell configuration and the command-line
  # tools it hooks (Starship, Atuin, zoxide, carapace, direnv), git, jj, ssh.
  # interface.nix only declares the dotfiles.primary options here; its
  # launchers and checks need the desktop tooling below.
  den.aspects.user-shell.homeManager.imports = [
    ../../../modules/home
    ../../../modules/tooling/interface.nix
    ../../../modules/programs/shell/cli.nix
    ../../../modules/programs/shell/shell.nix
    ../../../modules/programs/ssh/ssh.nix
    ../../../modules/programs/vcs/vcs.nix
    ../../../modules/programs/shell/yazi.nix
    # The Claude Code CLI with its skills, hooks and MCP servers.
    ../../../modules/tooling/ai/claude/claude-code.nix
  ];

  # Workstations only: terminals, editors, agent clients, desktop apps and
  # the user services that go with them. modules/programs repeats the shell
  # files above, which the module system imports once.
  den.aspects.user-desktop.homeManager.imports = [
    ../../../modules/tooling/terminals/kitty.nix
    ../../../modules/tooling/terminals/ghostty.nix
    ../../../modules/tooling/editors/helix.nix
    ../../../modules/tooling/keymap-checks.nix
    ../../../modules/tooling/knowledge/iwe.nix
    ../../../modules/tooling/ai/shared/plugins.nix
    ../../../modules/tooling/ai/clients/t3code/t3code.nix
    ../../../modules/tooling/ai/clients/continuum-ide.nix
    ../../../modules/tooling/ai/clients/opencode.nix
    ../../../modules/tooling/ai/clients/opencode-desktop.nix
    ../../../modules/tooling/ai/claude/claude-desktop.nix
    ../../../modules/tooling/ai/clients/codex.nix
    ../../../modules/tooling/ai/clients/copilot.nix
    ../../../modules/home/files.nix
    ../../../modules/home/packages.nix
    ../../../modules/home/session/services.nix
    ../../../modules/programs
  ];
}
