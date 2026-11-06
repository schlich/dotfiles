{ inputs, ... }:

# HEX, dictation that types what you say into the focused field. Its user
# service does not start with the session: Mod+D in niri/config.kdl starts it,
# and from then on HEX hears Mod+D itself. On Wayland it reads the keyboard
# from /dev/input, so its host adds the user to the input group
# (hosts/asus/default.nix). The shortcut, mode, and model live in HEX's own
# settings.json, which its Settings window (`hex app`) writes.
{
  imports = [ inputs.hex.homeManagerModules.default ];

  programs.hex.enable = true;
}
