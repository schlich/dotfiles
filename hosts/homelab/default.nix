{ lib, ... }:

{
  system.nixos.tags = [ "homelab" ];

  # schlich was created here as UID 1000, which owns /home/schlich. NixOS
  # never renumbers an existing user, and Home Manager's activation refuses
  # to run under a UID other than the declared one.
  users.users.schlich.uid = 1000;

  # Add the generated file from the target machine at this path. The optional
  # import keeps the flake inspectable before that hardware-specific step is
  # complete, while the warning makes the deployment prerequisite explicit.
  imports = lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix;

  warnings = lib.optional (
    !builtins.pathExists ./hardware-configuration.nix
  ) "homelab has no hardware-configuration.nix; generate it on the target machine before deployment";

  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.limine = {
    enable = true;
    efiSupport = true;
    biosSupport = false;
    efiInstallAsRemovable = true;
    maxGenerations = 3;
  };

  system.stateVersion = "26.05";
}
