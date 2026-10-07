# `ci`: the launcher in ci-launch.nu, which picks the jj/ci.nu to run each
# time. This checkout's copy is bundled for repositories that have none.
# Shared by Home Manager, the dev shell, and the ci MCP server. Whichever
# jj/ci.nu the launcher runs inherits NU_LIB_DIRS, where it finds `pst`.
{ pkgs, osc7501-nu }:
pkgs.symlinkJoin {
  name = "ci";
  paths = [ (pkgs.writeNuScriptBin "ci" (builtins.readFile ./ci-launch.nu)) ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  meta.mainProgram = "ci";
  postBuild = ''
    # The launcher runs jj before any ci.nu. Append it so CI runners without
    # jj have one, while a user's own jj still comes first.
    wrapProgram "$out/bin/ci" --prefix PATH : ${pkgs.git}/bin:${pkgs.gh}/bin \
      --suffix PATH : ${pkgs.jujutsu}/bin \
      --prefix NU_LIB_DIRS : ${osc7501-nu} \
      --set CI_BUNDLED_SCRIPT ${./ci.nu}
    # Deprecated alias for the former `jj-ci` name.
    ln -s ci "$out/bin/jj-ci"
  '';
}
