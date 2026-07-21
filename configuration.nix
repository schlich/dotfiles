{
  config,
  pkgs,
  inputs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./system/hardware-configuration.nix
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/b1409dcc-54c2-4f90-8712-3c52aff50c20";
    fsType = "ext4";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.loader = {
    efi.canTouchEfiVariables = false;
    limine = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      maxGenerations = 10;
      biosSupport = false;
      extraEntries = ''
        /Windows
          comment: Boot the existing Windows Boot Manager EFI entry
          protocol: efi_boot_entry
          entry: Windows Boot Manager
      '';
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    allowed-users = [ "schlich" ];
  };
  nixpkgs.config.allowUnfree = true;

  # networking.networkmanager.enable = true;
  networking.wireless = {
    enable = true;
    networks."EvilCorp HQ".pskRaw = "37660d09044c0b74085b1604031b4a8ac965ed1bb10b07a5a2f797402ea10bd7";
  };
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  users.defaultUserShell = pkgs.nushell;
  users.users.schlich = {
    shell = pkgs.nushell;
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  environment = {
    shells = [ pkgs.nushell ];
    variables = {
      EDITOR = "hx";
      VISUAL = "hx";
    };
    systemPackages = with pkgs; [
      helix
      wget
      nix-search-tv
      nushell
      nil
      nixd
      htop
      swaylock
      pavucontrol
      vscode-json-languageserver
      # inputs.ragenix.packages.x86_64-linux.default
    ];
  };

  #  age.secrets.openai = {
  #    file = ./secrets/openai.age;
  #    owner = "nixos";
  #    mode = "0400";
  #  };

  services = {
    dbus.implementation = "broker";
    kmonad = {
      enable = true;
      keyboards.myKMonadOutput = {
        device = "/dev/input/by-id/usb-ROYUAN_ROYALAXE_R100-event-kbd";
        config = builtins.readFile ./system/kmonad.kbd;
      };
    };
    greetd = {
      settings.default_session = {
        user = "schlich";
        command = "${config.programs.niri.package}/bin/niri-session";
      };
      enable = true;
    };
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ "schlich" ];
      };
    };
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
  };

  hardware.enableAllFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.Experimental = true;
  };

  programs = {
    nix-ld.enable = true;
    niri.enable = true;
  };

  xdg = {
    portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-termfilechooser
      ];
    };
    autostart.enable = true;
  };

  security.polkit.enable = true;
  system.stateVersion = "26.05";
  systemd.user.services.niri.enableDefaultPath = false;
}
