{
  config,
  den,
  inputs,
  lib,
  ...
}:
let
  sharedRoot = "/srv/dev";

  # An agent account works for the host's personal users. They share
  # sharedRoot through the dev group; the agent never sees their homes,
  # keys, sudo, or Nix daemon trust.
  agentAccount =
    { host, user }:
    let
      personal = lib.filterAttrs (_: u: u.environment == "personal") host.users;
      operators = lib.attrNames personal;
      operator = lib.head (lib.attrNames (lib.filterAttrs (_: u: u.primary) personal) ++ operators);
    in
    lib.optionalAttrs (user.environment == "agent") {
      name = "agent-account/${user.userName}@${host.name}";
      nixos =
        { config, ... }:
        let
          account = config.users.users.${user.userName};
        in
        {
          # Commit as the primary operator, who reviews and publishes the
          # agent's changes; the agent holds no push credentials.
          home-manager.users.${user.userName}.accounts.email.accounts.personal = {
            inherit (config.home-manager.users.${operator}.accounts.email.accounts.personal)
              address
              realName
              userName
              ;
            primary = true;
          };

          users.groups.dev = { };
          users.users = {
            ${user.userName}.extraGroups = [ "dev" ];
          }
          // lib.genAttrs operators (_: {
            extraGroups = [ "dev" ];
          });

          # setgid keeps new entries in dev; the default ACL keeps them group
          # writable regardless of either account's umask.
          systemd.tmpfiles.rules = [
            "d ${sharedRoot} 2770 root dev -"
            "a+ ${sharedRoot} - - - - default:group:dev:rwx,default:mask::rwx,group:dev:rwx,mask::rwx"
          ];

          # Repositories under sharedRoot are owned by whichever account
          # created them.
          programs.git = {
            enable = true;
            config.safe.directory = "${sharedRoot}/*";
          };

          # Operators enter the agent account with `machinectl shell
          # ${user.userName}@` and no password; no other target is widened.
          security.polkit.extraConfig = ''
            polkit.addRule(function (action, subject) {
              if (action.id == "org.freedesktop.machine1.host-shell" &&
                  action.lookup("user") == "${user.userName}" &&
                  ${builtins.toJSON operators}.indexOf(subject.user) >= 0) {
                return polkit.Result.YES;
              }
            });
          '';

          assertions =
            map
              (group: {
                assertion = !(lib.elem group account.extraGroups);
                message = "agent account ${user.userName} must not be in the ${group} group";
              })
              [
                "wheel"
                "docker"
                "libvirtd"
              ]
            ++ [
              {
                assertion = !(lib.elem user.userName config.nix.settings.trusted-users);
                message = "agent account ${user.userName} must not be a Nix trusted user";
              }
              {
                assertion = !(lib.elem user.userName (config.services.openssh.settings.AllowUsers or [ ]));
                message = "agent account ${user.userName} must not accept SSH logins";
              }
              {
                assertion = operators != [ ];
                message = "agent account ${user.userName} needs a personal user on ${host.name}";
              }
            ];
        };
    };
in
{
  den.aspects.user-agent-account.includes = [ agentAccount ];

  den.aspects.agent = {
    meta = config.myConfig.aspectPolicy.agent-account;
    includes = [
      den.batteries.define-user
      den.aspects.user-agent-account
      den.aspects.user-agent-tools
    ];
    nixos =
      { pkgs, ... }:
      {
        users.users.agent.shell = pkgs.nushell;
      };
    homeManager =
      { pkgs, ... }:
      {
        home.stateVersion = "26.05";
        dotfiles = {
          alternates = false;
          # The account has no graphical session: its terminal is the one
          # `machinectl shell` already opened.
          tooling.terminals.shell.launcher = ''
            cd $directory
            if ($args | is-empty) { exec ${pkgs.nushell}/bin/nu } else { exec ...$args }
          '';
          tooling.editors.helix.command = "${pkgs.helix}/bin/hx";
          primary = {
            terminal = "shell";
            editor = "helix";
            ai = "opencode";
            desktopAgent = "opencode";
          };
        };
      };
  };

  # The coding agents and their shared configuration, without the desktop,
  # SSH identities, or personal knowledge base.
  den.aspects.user-agent-tools.homeManager.imports = [
    inputs.codex-desktop-linux.homeManagerModules.default
    ../../../modules/tooling/interface.nix
    ../../../modules/tooling/ai/plugins.nix
    ../../../modules/tooling/ai/opencode.nix
    ../../../modules/tooling/ai/claude-code.nix
    ../../../modules/tooling/ai/codex.nix
    ../../../modules/programs/shell.nix
    ../../../modules/programs/vcs.nix
  ];
}
