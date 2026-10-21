{ inputs, pkgs, ... }:

# HEX, dictation that types what you say into the focused field. Its user
# service does not start with the session: Mod+D in niri/config.kdl starts it,
# and from then on HEX hears Mod+D itself. On Wayland it reads the keyboard
# from /dev/input, so its host adds the user to the input group
# (hosts/asus/default.nix). The shortcut, mode, and model live in HEX's own
# settings.json, which its Settings window (`hex app`) writes.
let
  hex = inputs.hex.packages.${pkgs.stdenv.hostPlatform.system}.hex;
in
{
  imports = [ inputs.hex.homeManagerModules.default ];

  programs.hex = {
    enable = true;
    # Two packaging faults in anomalyco/hex at the locked revision; drop each
    # override once its nix/package.nix fixes it:
    # - its hash for the gpui fork does not match that commit's source, with
    #   its own nixpkgs pin or ours; Cargo.lock pins the commit, so this
    #   records what it fetches.
    # - a test reads macos/HexMicrophoneDriver/Info.plist, which the package's
    #   source fileset leaves out, so the check phase cannot compile.
    package = hex.overrideAttrs {
      doCheck = false;
      cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = "${inputs.hex}/Cargo.lock";
        outputHashes = {
          "transcribe-rs-0.3.11" = "sha256-MJJiug3LfbKsuHcL2+LJk95+j5kk/MWzb5ihdBlHLmE=";
          "gpui-0.2.2" = "sha256-LtFxryxm3guT3e+Sa7sUI9u7ErplqMaWlJyaJlRguRw=";
        };
      };
    };
  };
}
