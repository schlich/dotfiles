{ pkgs, ... }:

{
  system.stateVersion = "26.05";

  # imports = [
  #   ./hardware-configuration.nix
  # ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    allowed-users = [ "schlich" ];
  };
  nixpkgs.config.allowUnfree = true;

  hardware.enableAllFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
      };
    };
  };

  boot.loader = {
    # Install Limine to the USB drive's fallback EFI path so firmware can boot it
    # without relying on host-specific NVRAM entries.
    efi.canTouchEfiVariables = false;
    limine = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      biosSupport = false;
      extraEntries = ''
        /Windows
          comment: Boot the existing Windows Boot Manager EFI entry
          protocol: efi_boot_entry
          entry: Windows Boot Manager
      '';
    };
  };

  networking.hostName = "nixos";
  networking.wireless.enable = false; # Enables wireless support via wpa_supplicant.

  # networking.networkmanager.enable = true;
  networking.wireless.networks = {
    "EvilCorp HQ" = {
      psk = "drastic-overview-sepia";
    };
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

  services = {
    kmonad = {
      enable = true;
      keyboards = {
        myKMonadOutput = {
          device = "/dev/input/by-id/usb-ROYUAN_ROYALAXE_R100-event-kbd";
          config = builtins.readFile ./kmonad.kbd;
        };
      };
    };
    # dbus.packages = [ pkgs.gcr ];
    greetd = {
      enable = true;
      # settings.default_session.user = "schlich";
    };
    # displayManager.dms-greeter = {
    # enable = true;
    # compositor.name = "niri";
    # package = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.default;
    # };
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
    # xserver = {
    #   enable = true;
    #   xkb.options = "caps:escape";
    # };
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.schlich = {
    isNormalUser = true;
    description = "Ty Schlichenmeyer";
    extraGroups = [
      "wheel"
      "input"
      "seat"
      "uinput"
    ];
    shell = pkgs.nushell;
    packages = with pkgs; [
      monaspace
      opencode
    ];
  };

  environment.systemPackages = with pkgs; [
    # lxqt.lxqt-wayland-session
    nix-search-tv
    nushell
    nil
    nixd
    # fuzzel
    # pixi
    htop
    swaylock
    pavucontrol
    vscode-json-languageserver

  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs = {
    # ssh.startAgent = true;
    nix-ld.enable = true;
    niri = {
      enable = true;
      # settings.input.keyboard.xkb.options = "caps:escape";
    };
  };
  services.dbus.implementation = "broker";
  xdg = {
    portal = {
      enable = true;
      # lxqt.enable = true;
      extraPortals = [
        # pkgs.lxqt.xdg-desktop-portal-lxqt
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-termfilechooser
      ];
    };
    # xdgOpenUsePortal = true;
    autostart.enable = true;
  };
  # virtualisation.docker = {
  # enable = false;
  # rootless = {
  #   enable = true;
  #   setSocketVariable = true;
  # };
  # };
  security.polkit.enable = true;
  age.secrets.openai = {
    file = ./secrets/openai.age;
    owner = "schlich";
    mode = "0400";
  };
}
