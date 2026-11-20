{ ... }:

{
  imports = [
    ./shell/cli.nix
    ./vcs/dagger.nix
    ./desktop/desktop.nix
    ./shell/devenv.nix
    ./desktop/dicta.nix
    ./desktop/hex.nix
    ./desktop/hokum.nix
    ./desktop/input-stack.nix
    ./vcs/jj-hunk.nix
    ./multiplexers/luvus.nix
    ./shell/shell.nix
    ./ssh/ssh.nix
    ./vcs/vcs.nix
    ./shell/yazi.nix
  ];
}
