{ pkgs }:

let
  # `--stdin` exposes the hook payload as `$in`; writeNuScriptBin omits it.
  script = pkgs.writeTextFile {
    name = "dicta";
    destination = "/bin/dicta";
    executable = true;
    text = "#!${pkgs.nushell}/bin/nu --stdin\n" + builtins.readFile ./dicta.nu;
  };
  # English base model: quick enough on a laptop CPU for short spoken notes.
  model = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
    hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
  };
  dicta = pkgs.symlinkJoin {
    name = "dicta";
    paths = [ script ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # niri and systemctl come from the session, which must match the running
    # compositor and user manager.
    postBuild = ''
      wrapProgram "$out/bin/dicta" \
        --set DICTA_SELF "$out/bin/dicta" \
        --set-default DICTA_MODEL ${model} \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.coreutils
            pkgs.libnotify
            pkgs.pipewire
            pkgs.whisper-cpp
            pkgs.wl-clipboard-rs
          ]
        }
    '';
  };
  # A Noctalia `path` plugin source: one directory per plugin.
  noctaliaPlugins = pkgs.runCommand "dicta-noctalia-plugins" { } ''
    install -Dm644 ${./noctalia/plugin.toml} $out/dicta/plugin.toml
    install -Dm644 ${
      pkgs.replaceVars ./noctalia/widget.luau { dicta = "${dicta}/bin/dicta"; }
    } $out/dicta/widget.luau
  '';
in
dicta.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit noctaliaPlugins;
  };
})
