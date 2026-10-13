# Couples a program to its configuration instead of linking files into
# $HOME: each wrapped executable gets environment variables and leading flags
# that name store files. Wrappers work wherever /nix/store is visible,
# including the Claude Desktop sandbox, which hides host /etc and rejects
# store symlinks under ~/.ssh. `--set` beats Home Manager session variables
# that still name the old $HOME path.
{ lib, pkgs }:

{
  package,
  programs ? [ (package.meta.mainProgram or (lib.getName package)) ],
  env ? { },
  flags ? [ ],
  # Runs after wrapping, for files such as service units that name the
  # unwrapped executable by store path.
  postBuild ? "",
}:

let
  wrapArgs = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: value: "--set ${lib.escapeShellArg name} ${lib.escapeShellArg value}") env
    ++ lib.optional (flags != [ ]) "--add-flags ${lib.escapeShellArg (lib.escapeShellArgs flags)}"
  );
in
pkgs.symlinkJoin {
  inherit (package) name;
  # Join the outputs a profile would install, such as man pages, into the
  # wrapper's single output.
  paths = map (output: package.${output}) (
    lib.filter (output: package ? ${output}) (package.meta.outputsToInstall or [ "out" ])
  );
  nativeBuildInputs = [ pkgs.makeWrapper ];
  passthru = (package.passthru or { }) // {
    unwrapped = package;
  };
  meta = (package.meta or { }) // {
    outputsToInstall = [ "out" ];
  };
  postBuild =
    lib.concatMapStrings (program: ''
      wrapProgram "$out/bin/${program}" ${wrapArgs}
    '') programs
    + postBuild;
}
