{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# Rex, the terminal multiplexer, from its prebuilt snapshot flake: the rex
# command, its xterm-rex terminfo entry in ~/.terminfo, and a personal server
# as the `rex` systemd user service. `loginctl enable-linger` keeps the
# server running while logged out. Agents get what `rex skill setup` would
# install: the rex skill, and a SessionStart hook in Claude Code and Codex.
#
# Rex has no interactive client for Linux yet; Rex.app on macOS is the only
# one released. Here `rex` is the command-line client, and `-S LABEL` sends a
# command to one of the hosts below instead of this machine's server.
let
  cfg = config.dotfiles.rex;
  rex = lib.getExe config.programs.rex.package;
  jq = lib.getExe pkgs.jq;

  # What `rex skill setup` installs, generated from the package at build time
  # so it follows Rex upgrades. Setup needs no server, network, or runtime
  # directory. Session naming stays off, as a plain setup leaves it.
  #
  #   claude-skill/, agents-skill/  the rex skill stub
  #   claude-plugin/                its SessionStart hook as a Claude Code
  #                                 plugin; Claude Code rewrites settings.json
  #                                 at runtime and keeps plugins beside skills
  #                                 in ~/.claude/skills, hence `rex-session`
  #   codex/hooks.json              Rex's Codex hooks file, for reference
  #   codex/session-start           the command from that file, as a script
  #
  # Each hook command's bare `rex` becomes the package's store path; should
  # Rex change the command's shape, the substitution misses and it falls back
  # to PATH.
  codexHook = {
    timeout = 5;
    statusMessage = "Loading Rex terminal context";
  };
  agentFiles =
    pkgs.runCommand "rex-agent-files"
      {
        nativeBuildInputs = [ pkgs.jq ];
        inherit rex;
        pinRex = ''.hooks.SessionStart[].hooks[].command |= sub("-c 'rex "; "-c '\($rex) ")'';
        plugin = builtins.toJSON {
          name = "rex-session";
          description = "Tell each session which Rex session and terminal it runs in.";
        };
      }
      ''
        export HOME=$TMPDIR/home
        mkdir -p $HOME
        $rex skill setup --autostart=false --agent claude --agent codex --agent opencode

        mkdir -p $out
        cp -r $HOME/.claude/skills/rex $out/claude-skill
        cp -r $HOME/.agents/skills/rex $out/agents-skill

        install -Dm644 /dev/stdin $out/claude-plugin/.claude-plugin/plugin.json <<<"$plugin"
        mkdir -p $out/claude-plugin/hooks $out/codex
        jq --arg rex "$rex" '{hooks: .hooks}' $HOME/.claude/settings.json \
          | jq --arg rex "$rex" "$pinRex" >$out/claude-plugin/hooks/hooks.json
        jq --arg rex "$rex" "$pinRex" $HOME/.codex/hooks.json >$out/codex/hooks.json

        # Codex's hook entry is declared in Nix (see programs.codex below), so
        # fail the build if Rex's own entry stops matching it.
        jq -e '.hooks.SessionStart | length == 1 and (.[0].hooks | length == 1)
                 and .[0].hooks[0].timeout == ${toString codexHook.timeout}
                 and .[0].hooks[0].statusMessage == "${codexHook.statusMessage}"' \
          $out/codex/hooks.json >/dev/null
        {
          echo '#!${pkgs.runtimeShell}'
          echo "exec $(jq -r '.hooks.SessionStart[0].hooks[0].command' $out/codex/hooks.json)"
        } >$out/codex/session-start
        chmod +x $out/codex/session-start
      '';

  # The server's init.lua, kept in the store and named by REX_CONFIG rather
  # than linked into ~/.config/rex. It loads nurx's `nurx_pick` action, which
  # stays idle until a Rex app connects to answer rex.ui prompts.
  initLua = pkgs.writeText "rex-init.lua" ''
    dofile("${inputs.nu-rex-integration}/nurx.lua")
  '';
in
{
  imports = [
    inputs.rex.homeManagerModules.default
    # `notebook`: marimo notebooks in Rex terminals, here or on a host.
    ./rex-notebooks
  ];

  options.dotfiles.rex.hosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      homelab = "https://homelab.example.ts.net:7297";
    };
    description = ''
      Other Rex servers to reach by label, as in `rex -S homelab ls`. Rex
      keeps hosts as runtime state on the account's home server, so
      activation adds each missing label there and leaves an existing one
      alone, and `rex hosts edit` keeps working.
    '';
  };

  config = {
    programs.rex = {
      enable = true;
      # The guard needs Home Manager's programs.ssh, which this repository does
      # not use; ssh.nix includes it in the wrapped ssh's config instead.
      sshGuard = false;
    };
    services.rex = {
      enable = true;
      environment.REX_CONFIG = "${initLua}";
    };
    # `rex config check` and other CLI reads of the config find the same file.
    home.sessionVariables.REX_CONFIG = "${initLua}";

    # Claude Code reads the skill from ~/.claude/skills and its hooks from a
    # plugin, since it rewrites settings.json at runtime. Codex and OpenCode
    # share ~/.agents/skills; OpenCode has no command hooks.
    programs.claude-code = lib.mkIf config.programs.claude-code.enable {
      skills.rex = "${agentFiles}/claude-skill";
      plugins.rex-session = "${agentFiles}/claude-plugin";
    };
    home.file.".agents/skills/rex".source = "${agentFiles}/agents-skill";
    # Luvus also sets programs.codex.hooks (modules/programs/multiplexers/
    # luvus.nix), so Rex's generated hooks.json cannot be the whole file, and
    # reading it here would be import-from-derivation. The entry is declared
    # instead and runs the generated command; the build checks its fields.
    programs.codex = lib.mkIf config.programs.codex.enable {
      hooks.SessionStart = [
        {
          hooks = [
            (
              {
                type = "command";
                command = "${agentFiles}/codex/session-start";
              }
              // codexHook
            )
          ];
        }
      ];
    };

    # After the switch's own units start, so the server is normally up; when
    # it is not, the hosts wait for the next activation.
    home.activation.rexHosts = lib.mkIf (cfg.hosts != { }) (
      lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        if known=$(${rex} --autostart=false hosts list --json 2>/dev/null); then
          for entry in ${
            lib.escapeShellArgs (lib.mapAttrsToList (label: endpoint: "${label}=${endpoint}") cfg.hosts)
          }; do
            label=''${entry%%=*}
            endpoint=''${entry#*=}
            if ! ${jq} --exit-status --arg label "$label" \
              'any(.hosts[]; .host.label | ascii_downcase == ($label | ascii_downcase))' \
              <<<"$known" >/dev/null; then
              run ${rex} --autostart=false hosts add "$label" "$endpoint" \
                || warnEcho "rex: could not add host $label ($endpoint)"
            fi
          done
        else
          warnEcho "rex: the Rex server is not running, so hosts were not added: ${lib.concatStringsSep ", " (lib.attrNames cfg.hosts)}"
        fi
      ''
    );

    dotfiles.nixpkgsWatchExempt.rex = "the vendor's prebuilt, closed-source release; nixpkgs' rex is an unrelated Perl tool";
  };
}
