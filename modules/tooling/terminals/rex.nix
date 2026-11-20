{ inputs, ... }:

# Rex, the terminal multiplexer, from its prebuilt snapshot flake: the rex
# command, its xterm-rex terminfo entry in ~/.terminfo, and a personal server
# as the `rex` systemd user service. `loginctl enable-linger` keeps the
# server running while logged out.
{
  imports = [ inputs.rex.homeManagerModules.default ];

  programs.rex = {
    enable = true;
    # The guard needs Home Manager's programs.ssh, which this repository does
    # not use; ssh.nix includes it in the wrapped ssh's config instead.
    sshGuard = false;
  };
  services.rex.enable = true;

  dotfiles.nixpkgsWatchExempt.rex = "the vendor's prebuilt, closed-source release; nixpkgs' rex is an unrelated Perl tool";
}
