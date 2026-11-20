{ inputs, ... }:

# HEX, dictation that types what you say into the focused field. Its user
# service does not start with the session: Mod+D in niri/binds.nix starts it,
# and from then on HEX hears Mod+D itself. On Wayland it reads the keyboard
# from /dev/input, so its host adds the user to the input group
# (hosts/asus/default.nix). The shortcut, mode, and model live in HEX's own
# settings.json, which its Settings window (`hex app`) writes.
{
  imports = [ inputs.hex.homeManagerModules.default ];

  # Off while HEX 3.4.0 cannot build on homelab: one of its compile steps
  # stays silent past nixbot's 1200 s limit (and over an hour unbounded),
  # failing gateChecks desktop-home. Turn it back on once it builds; until
  # then Mod+D and Mod+Shift+D in niri/binds.nix start nothing.
  programs.hex.enable = false;
}
