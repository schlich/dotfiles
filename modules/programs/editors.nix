{ pkgs, ... }:

{
  programs.helix = {
    enable = true;
    extraPackages = with pkgs; [
      nixd
      nil
      nixfmt
      marksman
    ];
    defaultEditor = true;
    settings = {
      theme = "dracula";
      editor.line-number = "relative";
    };
  };

  programs.zed-editor.enable = true;
}
