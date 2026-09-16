{
  lib,
  buildNpmPackage,
  fetchurl,
  gnutar,
  nodejs,
  runCommand,
}:

buildNpmPackage rec {
  pname = "openchamber";
  version = "1.23.2";

  src =
    runCommand "${pname}-source-${version}.tar.gz"
      {
        nativeBuildInputs = [
          gnutar
          nodejs
        ];
      }
      ''
        mkdir -p source
        tar -xzf ${
          fetchurl {
            url = "https://registry.npmjs.org/@openchamber/web/-/web-${version}.tgz";
            hash = "sha512-oKIrhpUVzvazp1eYn3rUSiYcCRWcBl6Xu4aUl6yBG9TBhcb1bOjoj+a8S0RdGI0j7gLRuUq7BslgKViI7C43Qg==";
          }
        } -C source
        cp ${./openchamber-package-lock.json} source/package/package-lock.json
        chmod u+w source/package/package-lock.json
        node -e 'const fs = require("fs"); const path = process.argv[1]; fs.writeFileSync(path, JSON.stringify(JSON.parse(fs.readFileSync(path, "utf8")), null, 2) + "\n");' source/package/package-lock.json
        tar -czf "$out" -C source package
      '';

  sourceRoot = "package";
  npmDepsHash = "sha256-6GxhqlD3KPMAgjkYgszoxIaHJbhWGKwOqg6N/tLvquw=";

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    install -d "$out/lib/node_modules/@openchamber/web" "$out/bin"
    cp -R . "$out/lib/node_modules/@openchamber/web/"
    ln -s "$out/lib/node_modules/@openchamber/web/bin/cli.js" "$out/bin/openchamber"

    runHook postInstall
  '';

  meta = {
    description = "Web interface for OpenCode";
    homepage = "https://openchamber.dev/";
    license = lib.licenses.mit;
    mainProgram = "openchamber";
    platforms = lib.platforms.linux;
  };
}
