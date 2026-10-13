{
  config,
  inputs,
  lib,
  pkgs,
  utils,
  ...
}:

# Ephemeral @root and @home on asus. Persisted paths live in the @persist
# subvolume and are bind-mounted back into place; persist-paths.nix lists
# them. Roll out in order:
#   1. `sudo persist-migrate` snapshots @root and @home, creates @persist,
#      and copies every listed path and the login password hashes into it.
#   2. Set `enable` and boot the result with `nixos-rebuild boot`, then
#      reboot. A live switch would mount the copies over running state.
#   3. Run `sudo fs-diff` until it lists nothing you want to keep, adding
#      paths to persist-paths.nix and copying them with `persist-migrate`.
#   4. Set `wipe` and reboot. Retired subvolumes stay in @old-roots for 30
#      days.
let
  cfg = config.impermanence;
  paths = import ./persist-paths.nix;

  rootFs = config.fileSystems."/";
  # The top-level subvolume holds @root, @home, @persist and @old-roots.
  topLevel = rootFs.device;
  ephemeralSubvolumes = [
    "@root"
    "@home"
  ];
  retentionDays = 30;
  # Users whose login password moves from /etc/shadow to @persist.
  passwordUsers = [
    "root"
    "schlich"
  ];

  entryPath = entry: if builtins.isString entry then entry else entry.directory or entry.file;
  userPaths =
    name: user:
    map (entry: "${config.users.users.${name}.home}/${entryPath entry}") (
      user.directories ++ user.files
    );
  spec = pkgs.writeText "persist-spec.json" (
    builtins.toJSON {
      device = topLevel;
      inherit ephemeralSubvolumes passwordUsers;
      entries =
        map entryPath (paths.system.directories ++ paths.system.files)
        ++ lib.concatLists (lib.mapAttrsToList userPaths paths.users);
      # Regenerated at every boot from the NixOS configuration.
      regenerated = [
        "/tmp"
        "/var/tmp"
        "/etc/NIXOS"
        "/etc/.clean"
        "/etc/.updated"
        "/etc/.pwd.lock"
        "/etc/passwd"
        "/etc/passwd-"
        "/etc/group"
        "/etc/group-"
        "/etc/shadow"
        "/etc/shadow-"
        "/etc/subuid"
        "/etc/subgid"
        "/etc/sudoers"
        "/etc/logrotate.conf"
        "/etc/resolv.conf"
      ];
    }
  );

  persistMigrate = pkgs.writers.writeNuBin "persist-migrate" ''
    # Snapshot @root and @home, then copy every persisted path and the login
    # password hashes into @persist. Paths already in @persist are kept.
    def main [] {
      if (^id -u | str trim) != "0" {
        error make { msg: "Run persist-migrate with sudo." }
      }
      let spec = (open ${spec})
      let top = "/run/persist-migrate"
      mkdir $top
      ^${pkgs.util-linux}/bin/mount -t btrfs -o subvolid=5 $spec.device $top
      let outcome = (try {
        # Kept outside @old-roots so the rollback's pruning never removes them.
        let stamp = (date now | format date "%Y-%m-%d_%H%M%S")
        mkdir $"($top)/@pre-impermanence"
        for sv in $spec.ephemeralSubvolumes {
          ^${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r $"($top)/($sv)" $"($top)/@pre-impermanence/($sv)-($stamp)"
        }
        let persist = $"($top)/@persist"
        if not ($persist | path exists) {
          ^${pkgs.btrfs-progs}/bin/btrfs subvolume create $persist
        }

        let copied = ($spec.entries | each {|src|
          if ($"($persist)($src)" | path exists --no-symlink) {
            { path: $src, result: kept }
          } else if not ($src | path exists --no-symlink) {
            { path: $src, result: absent }
          } else {
            # --parents with -a keeps the owners and modes of parent
            # directories, which the bind mounts copy onto / and /home.
            ^cp -a --parents --reflink=auto $src $persist
            { path: $src, result: copied }
          }
        })

        let shadow = (open --raw /etc/shadow | lines | each {|l| $l | split row ":" } | each {|f| { user: $f.0, hash: $f.1 } })
        mkdir $"($persist)/passwords"
        ^chmod 700 $"($persist)/passwords"
        let passwords = ($spec.passwordUsers | each {|u|
          let hash = ($shadow | where user == $u | get -o 0.hash | default "")
          if ($hash | str starts-with "$") {
            $hash | save --force $"($persist)/passwords/($u)"
            ^chmod 600 $"($persist)/passwords/($u)"
            { user: $u, password: saved }
          } else {
            { user: $u, password: "none set; account stays locked" }
          }
        })
        if not ($"($persist)/passwords/schlich" | path exists) {
          error make { msg: "No password hash for schlich in /etc/shadow; set one with passwd and rerun." }
        }
        { ok: true, copied: ($copied | group-by result | transpose result paths | each {|r| { result: $r.result, count: ($r.paths | length) } }), absent: ($copied | where result == absent | get path), passwords: $passwords, snapshots: $"@pre-impermanence/*-($stamp)" }
      } catch {|err|
        { ok: false, error: $err.msg }
      })
      ^${pkgs.util-linux}/bin/umount $top
      if not $outcome.ok {
        error make { msg: $outcome.error }
      }
      $outcome | reject ok
    }
  '';

  fsDiff = pkgs.writers.writeNuBin "fs-diff" ''
    # List files on / and /home that no persisted path covers: what the next
    # wipe would destroy. Links into the Nix store are recreated and skipped.
    def main [
      --all # List every file instead of totals per directory
    ] {
      let spec = (open ${spec})
      let pruned = ($spec.entries | append $spec.regenerated)
      let prune_args = ($pruned | each {|p| [ "-path" $p "-o" ] } | flatten | drop)
      let found = (^find / /home -xdev "(" ...$prune_args ")" -prune -o "(" -type f -o -type l ")" -printf "%s\t%y\t%l\t%p\n" | complete)
      let rows = ($found.stdout | lines | parse "{size}\t{type}\t{target}\t{path}"
        | where {|r| not ($r.type == "l" and ($r.target =~ '^(/nix/store|/etc/static)/')) }
        | update size {|r| $r.size | into int | into filesize })
      if $all {
        return ($rows | select path size)
      }
      $rows
        | insert dir {|r| let parts = ($r.path | path split); let depth = (if ($parts | get -o 1) == "home" { 4 } else { 3 }); $parts | first $depth | path join }
        | group-by dir
        | transpose dir files
        | each {|g| { dir: $g.dir, files: ($g.files | length), size: ($g.files | get size | math sum) } }
        | sort-by size --reverse
    }
  '';
in
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  options.impermanence = {
    enable = lib.mkEnableOption "the @persist subvolume and its bind mounts";
    wipe = lib.mkEnableOption "retiring @root and @home to blank subvolumes at every boot";
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [
        persistMigrate
        fsDiff
      ];
    }

    (lib.mkIf cfg.enable {
      environment.persistence."/persist" = {
        hideMounts = true;
        inherit (paths.system) directories files;
        inherit (paths) users;
      };

      # /etc/shadow is wiped with @root, so passwords are declared from the
      # hashes persist-migrate saved.
      users.mutableUsers = false;
      users.users = lib.genAttrs passwordUsers (user: {
        hashedPasswordFile = "/persist/passwords/${user}";
      });
    })

    (lib.mkIf cfg.wipe {
      assertions = [
        {
          assertion = cfg.enable;
          message = "impermanence.wipe needs impermanence.enable, or nothing survives a reboot.";
        }
        {
          assertion = config.boot.resumeDevice == "";
          message = "impermanence.wipe would destroy a hibernated session; it cannot be used with resume.";
        }
      ];

      boot.initrd.systemd.services.impermanence-rollback = {
        description = "Retire @root and @home and start from blank subvolumes";
        wantedBy = [ "initrd.target" ];
        requires = [ "${utils.escapeSystemdPath topLevel}.device" ];
        after = [ "${utils.escapeSystemdPath topLevel}.device" ];
        before = [
          "sysroot.mount"
          "sysroot-home.mount"
        ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        path = [
          pkgs.btrfs-progs
          pkgs.coreutils
          pkgs.findutils
          pkgs.util-linux
        ];
        script = ''
          set -euo pipefail
          top=/impermanence-top
          mkdir -p "$top"
          mount -t btrfs -o subvolid=5 ${topLevel} "$top"
          trap 'umount "$top"' EXIT

          delete_recursively() {
            local child
            btrfs subvolume list -o "$1" | cut -f 9- -d ' ' | while IFS= read -r child; do
              delete_recursively "$top/$child"
            done
            btrfs subvolume delete "$1"
          }

          mkdir -p "$top/@old-roots"
          stamp=$(date +%Y-%m-%d_%H%M%S)
          for sv in ${lib.escapeShellArgs ephemeralSubvolumes}; do
            if [ -e "$top/$sv" ]; then
              mv "$top/$sv" "$top/@old-roots/$sv-$stamp"
              # Age retired subvolumes from now, not from their last change.
              touch "$top/@old-roots/$sv-$stamp"
            fi
            btrfs subvolume create "$top/$sv"
          done

          find "$top/@old-roots" -mindepth 1 -maxdepth 1 -mtime +${toString retentionDays} -print0 |
            while IFS= read -r -d "" old; do
              delete_recursively "$old"
            done
        '';
      };
    })
  ];
}
