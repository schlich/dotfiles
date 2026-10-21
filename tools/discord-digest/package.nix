# discord-digest from nixpkgs' Python packages. The tests run in the check
# phase, so building the package is its flake check.
{ lib, python3Packages }:

python3Packages.buildPythonApplication {
  pname = "discord-digest";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./README.md
      ./src
      ./tests
    ];
  };

  build-system = [ python3Packages.hatchling ];
  dependencies = with python3Packages; [
    anthropic
    httpx
    pydantic
  ];
  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  meta = {
    description = "Reads your Discord channels once a day and relays what looks worth your time to a dashboard";
    mainProgram = "discord-digest";
  };
}
