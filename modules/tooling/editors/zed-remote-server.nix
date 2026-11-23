{
  lib,
  pkgs,
  ...
}:

let
  binaryName = pkgs.zed-editor.remoteServerExecutableName;
in
{
  # Symlink only the `remote_server` output at the path Zed looks for on SSH
  # hosts (matching Home Manager's `programs.zed-editor.installRemoteServer`,
  # without pulling Zed's GUI closure onto servers).
  home.file.".zed_server/${binaryName}".source = lib.getExe' pkgs.zed-editor.remote_server binaryName;
}
