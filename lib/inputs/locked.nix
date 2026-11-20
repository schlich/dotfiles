{ lib, root }:

# Nix reads a group flake's inputs only when the lock has no entry for the
# group, so an input added to or removed from a group's flake.nix is ignored,
# silently, until that input is named to `nix flake update`. This lists every
# such difference between the group flakes and flake.lock, each with the
# command that settles it; the `inputs-locked` flake check fails on any.
let
  lock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
  isGroup = node: (node.locked.type or null) == "path" && node ? parent;

  group =
    path: key:
    let
      node = lock.nodes.${key};
      locked = builtins.attrNames (node.inputs or { });
      declared = builtins.attrNames (import (root + "/lib/inputs/${path}/flake.nix")).inputs;
      fix = name: "nix flake update ${path}/${name}";
    in
    map (name: "${path}/${name} is declared but not locked: ${fix name}") (
      lib.subtractLists locked declared
    )
    ++ map (name: "${path}/${name} is locked but no longer declared: ${fix name}") (
      lib.subtractLists declared locked
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: member:
        lib.optionals (builtins.isString member && isGroup lock.nodes.${member}) (
          group "${path}/${name}" member
        )
      ) (node.inputs or { })
    );
in
lib.concatLists (lib.mapAttrsToList group lock.nodes.${lock.root}.inputs)
