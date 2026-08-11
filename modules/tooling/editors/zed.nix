{ pkgs, ... }:

{
  programs.zed-editor.enable = true;
  dotfiles.tooling.editors.zed.command = "${pkgs.zed-editor}/bin/zeditor";
}
