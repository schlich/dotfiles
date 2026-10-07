{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:

let
  jjCi = import ../../jj/ci-package.nix {
    inherit pkgs;
    inherit (inputs) osc7501-nu;
  };
in
{
  programs.git = {
    enable = true;
    settings.user = {
      name = config.accounts.email.accounts.personal.userName;
      email = config.accounts.email.accounts.personal.address;
    };
    # Claude Desktop runs sessions in a user namespace where Nix-store files
    # appear owned by `nobody`, so ssh refuses the Home Manager ~/.ssh/config
    # ("Bad owner or permissions") and every fetch or push to Tangled fails.
    # Naming the file with -F skips only that ownership check; ssh reads the
    # same configuration everywhere. jj fetches and pushes through git.
    settings.core.sshCommand = "ssh -F ${config.home.homeDirectory}/.ssh/config";
  };
  programs.gpg.enable = true;
  programs.lazygit.enable = false;
  xdg.configFile."git/config".text = ''
    [credential "https://github.com"]
      helper =
      helper = !${pkgs.gh}/bin/gh auth git-credential
    [credential "https://gist.github.com"]
      helper =
      helper = !${pkgs.gh}/bin/gh auth git-credential
  '';
  programs.jjui.enable = true;

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        email = "ty.schlich@gmail.com";
        name = "schlich";
      };
      ui.diff-formatter = [
        "difft"
        "--color=always"
        "$left"
        "$right"
      ];
      fix.tools.nixfmt = {
        command = [
          "nixfmt"
          "--filename=$path"
        ];
        patterns = [ "glob:'**/*.nix'" ];
      };
      fix.tools.ruff-format = {
        command = [
          "ruff"
          "format"
          "--stdin-filename=$path"
          "-"
        ];
        patterns = [ "glob:'**/*.py'" ];
      };
      # Tangled hosts trunk; GitHub (origin) is only a mirror that `ci land` updates.
      git.push = "tangled";
      git.fetch = [
        "tangled"
        "origin"
      ];
      revset-aliases."trunk()" = "main@tangled";
      git.executable-path = "${pkgs.git}/bin/git";
    };
  };

  home.packages = [
    (pkgs.writeNuScriptBin "jj-describe" (builtins.readFile ../../jj/describe.nu))
    jjCi
    (pkgs.writeNuScriptBin "jj-dashboard" (builtins.readFile ../../jj/dashboard.nu))
    (import ../../jj/context-status.nix { inherit pkgs; })
  ];

  # Topics landed without `ci park`, tasks archived without it, and their
  # branches piled up: 15 workspaces and 17 landed `jj-*` branches stood on
  # 2026-10-07. Prune them daily. `--idle` leaves alone any workspace used in
  # the last day, without running JJ in it, so a live session is never
  # snapshotted; work above trunk is always kept.
  systemd.user.services.ci-prune = {
    Unit.Description = "Remove landed ci workspaces and topic branches";
    Service = {
      Type = "oneshot";
      WorkingDirectory = "${config.home.homeDirectory}/dotfiles";
      ExecStart = "${jjCi}/bin/ci prune --apply --idle 1day";
      Environment = [
        "PATH=${
          lib.makeBinPath [
            config.programs.jujutsu.package
            pkgs.openssh
            pkgs.util-linux
            pkgs.coreutils
          ]
        }"
        "SSH_AUTH_SOCK=%t/gcr/ssh"
      ];
    };
  };
  systemd.user.timers.ci-prune = {
    Unit.Description = "Prune landed ci workspaces and topic branches daily";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  xdg.configFile."nushell/autoload/ci.nu".source = ../../jj/completions.nu;
  # Refuses an interactive `jj new` that would strand a `ci` topic.
  xdg.configFile."nushell/autoload/jj-guard.nu".source = ../../jj/guard.nu;
  # `jw NAME` changes to a JJ workspace's root.
  xdg.configFile."nushell/autoload/jj-workspace.nu".source = ../../jj/workspace.nu;
}
