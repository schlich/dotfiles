{ config, inputs, ... }:

# dicta, the tape recorder for spoken review notes: Mod+M in niri/config.kdl
# records a take, the Claude Code hook (on with programs.claude-code) attaches
# it to the next prompt, and desktop.nix places the bar's recorder light.
{
  imports = [ inputs.dicta.homeManagerModules.default ];

  programs.dicta.enable = true;

  programs.noctalia.settings.plugins = {
    enabled = [ "schlich/dicta" ];
    source = [
      {
        name = "dicta";
        kind = "path";
        location = "${config.programs.dicta.package.noctaliaPlugins}";
        enabled = true;
      }
    ];
  };
}
