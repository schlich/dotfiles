# jj-mcp from npm, built ahead of time. Started through `npx`, every agent
# session also kept an idle `npm exec` parent of about 100 MB next to the
# server; this runs the server's script under node directly.
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs,
}:

buildNpmPackage {
  pname = "jj-mcp";
  version = "1.0.8";

  # package.json depends on exactly jj-mcp 1.0.8; package-lock.json is the
  # lock `npx -y jj-mcp@1.0.8` resolved.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
    ];
  };
  npmDepsHash = "sha256-G8ti1O5F4cuS2/SLbD7/BgVkpS3S0X7tD2fAhgLq5+4=";

  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -d "$out/lib"
    cp -R node_modules "$out/lib/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/jj-mcp" \
      --add-flags "$out/lib/node_modules/jj-mcp/dist/index.js"

    runHook postInstall
  '';

  meta = {
    description = "MCP server for the Jujutsu version control system";
    homepage = "https://www.npmjs.com/package/jj-mcp";
    license = lib.licenses.mit;
    mainProgram = "jj-mcp";
  };
}
