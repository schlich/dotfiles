{ config, ... }:

{
  home.file = {
    ".config/helix/llm.nu".source = ../../helix/llm.nu;
    ".config/helix/llm-tools.yaml".source = ../../helix/llm-tools.yaml;
    ".claude/skills/nushell".source =
      config.lib.file.mkOutOfStoreSymlink "/home/nixos/dotfiles/copilot/skills/nushell";
    ".claude/skills/jj".source =
      config.lib.file.mkOutOfStoreSymlink "/home/nixos/dotfiles/copilot/skills/jj";
  };
}
