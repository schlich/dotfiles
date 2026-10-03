# The executable-knowledge workbench: Nix environments named by document
# frontmatter (`environment: NAME`), their marimohub sandbox images, and the
# `workbench` CLI that runs a document in the environment it declares.
{
  pkgs,
  lib,
  iwe,
}:

let
  python = pkgs.python3;

  iweBridge = python.pkgs.buildPythonPackage {
    pname = "iwe-bridge";
    version = "0.1.0";
    pyproject = true;
    src = ./python;
    build-system = [ python.pkgs.setuptools ];
    pythonImportsCheck = [ "iwe_bridge" ];
  };

  # Each environments/NAME.nix is an environment; adding a file adds one.
  specs =
    lib.mapAttrs'
      (file: _: {
        name = lib.removeSuffix ".nix" file;
        value = import (./environments + "/${file}");
      })
      (
        lib.filterAttrs (file: type: type == "regular" && lib.hasSuffix ".nix" file) (
          builtins.readDir ./environments
        )
      );

  mkEnvironment =
    name: spec:
    let
      pythonEnv = python.withPackages (
        ps:
        [
          ps.marimo
          iweBridge
        ]
        ++ spec.python ps
      );
      runtime = pkgs.buildEnv {
        name = "workbench-${name}";
        paths = [
          pythonEnv
          iwe
        ]
        ++ spec.tools pkgs;
      };
    in
    {
      inherit name runtime;
      inherit (spec) description;
      python = pythonEnv;
      image = import ./image.nix {
        inherit
          pkgs
          lib
          name
          runtime
          ;
        python = pythonEnv;
        allowPypi = spec.allowPypi or false;
      };
    };

  environments = lib.mapAttrs mkEnvironment specs;

  imageRef = environment: "${environment.image.imageName}:${environment.image.imageTag}";

  manifest = pkgs.writeText "workbench-environments.json" (
    builtins.toJSON (
      lib.mapAttrs (_: environment: {
        inherit (environment) description;
        runtime = "${environment.runtime}";
        image = imageRef environment;
      }) environments
    )
  );

  cli = pkgs.writers.writeNuBin "workbench" (
    builtins.replaceStrings [ "@manifest@" "@iwe@" ] [ "${manifest}" "${iwe}/bin/iwe" ] (
      builtins.readFile ./workbench.nu
    )
  );
in
{
  inherit
    cli
    environments
    imageRef
    iweBridge
    manifest
    ;
}
