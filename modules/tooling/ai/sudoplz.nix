# sudoplz: a sudo askpass helper that shows each command an agent runs with
# `sudo -A` in a zenity dialog for approval. It stores the password with age
# against ~/.ssh/id_ed25519 when that key exists, or in the Secret Service
# keyring otherwise. Upstream has tagged nothing since 0.3.0, so this pins
# main at 0.5.0, which adds the policy file and audit log.
{
  lib,
  python3Packages,
  fetchFromGitHub,
  age,
  zenity,
}:

python3Packages.buildPythonApplication {
  pname = "sudoplz";
  version = "0.5.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "crypdick";
    repo = "sudoplz";
    rev = "14610846342d2b381a1148b4a7adc4f091229f15";
    hash = "sha256-wSQaD1LaxV3mESfFD5oc9z+Rzt76N1VkRXRn/XNO8/M=";
  };

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    bcrypt
    cryptography
    keyring
  ];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      age
      zenity
    ])
  ];

  pythonImportsCheck = [ "sudoplz" ];

  meta = {
    description = "GUI-approved sudo for AI coding agents";
    homepage = "https://github.com/crypdick/sudoplz";
    license = lib.licenses.mit;
    mainProgram = "sudoplz";
  };
}
