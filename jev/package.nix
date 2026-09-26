{ pkgs }:

let
  script = pkgs.writeNuScriptBin "jev" (builtins.readFile ./jev.nu);
in
pkgs.symlinkJoin {
  name = "jev";
  paths = [ script ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/jev" \
      --set-default JEV_QUESTIONS ${./questions.nuon} \
      --set-default JEV_SECRETSPEC_FILE ${../modules/secretspec.toml} \
      --prefix PATH : ${pkgs.secretspec}/bin
  '';
}
