# NixOS-WSL Host

This host sets `wsl.defaultUser` from the shared flake username so WSL, NixOS
users, and Home Manager all agree on the primary account.

When changing that username on an already installed WSL distro, use the
NixOS-WSL rename sequence rather than a normal switch:

```console
sudo nixos-rebuild boot --flake .#nixos-wsl
wsl -t NixOS
wsl -d NixOS --user root exit
wsl -t NixOS
```

Then open the distro normally. Adjust `NixOS` in the Windows commands if the
distro is registered under a different name.
