{ lib, root }:

# Counts the collections this repository asks a person to hold in mind:
# every directory's entries, and the lists inside a few files. The result
# is { "kind:name" = count; } for lib/honeycomb's audit.
let
  # Build output and dependency trees, which `path:` flakes include.
  skipped = [
    "node_modules"
    "packages"
    "target"
    "dist"
    "iwe.log"
  ];
  hiddenButCounted = [
    ".agents"
    ".github"
  ];
  counted =
    name:
    !(lib.elem name skipped)
    && !(lib.hasPrefix "result" name)
    && !(lib.hasPrefix "_" name)
    && !(lib.hasSuffix ".egg-info" name)
    && (!(lib.hasPrefix "." name) || lib.elem name hiddenButCounted);

  directories =
    relative:
    let
      entries = lib.filterAttrs (name: _: counted name) (
        builtins.readDir (if relative == "" then root else root + "/${relative}")
      );
      below = name: if relative == "" then name else "${relative}/${name}";
      children = lib.concatLists (
        lib.mapAttrsToList (
          name: type: lib.optionals (type == "directory") (directories (below name))
        ) entries
      );
    in
    [
      (lib.nameValuePair "dir:${if relative == "" then "." else relative}" (
        builtins.length (builtins.attrNames entries)
      ))
    ]
    ++ children;

  linesOf = file: lib.splitString "\n" (builtins.readFile (root + "/${file}"));
  matching =
    pattern: file:
    builtins.length (builtins.filter (line: builtins.match pattern line != null) (linesOf file));

  lock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
in
lib.listToAttrs (directories "")
// {
  "flake:inputs" = builtins.length (builtins.attrNames lock.nodes.${lock.root}.inputs);
  "niri:binds" =
    matching "[[:space:]]+(Mod|Alt|Ctrl|Super|Shift|XF86|Print)[A-Za-z0-9+_]*[[:space:]].*[{].*" "niri/config.kdl";
  "niri:window-rules" = matching "window-rule .*" "niri/config.kdl";
  "agents:sections" = matching "## .*" "AGENTS.md";
}
