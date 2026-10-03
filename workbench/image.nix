# A marimohub sandbox image whose software comes from one Nix closure.
#
# marimohub's container backends run `IMAGE sleep infinity`, then drive the
# kernel through `exec ... sh -lc`: `uv sync --inexact` against
# UV_PROJECT_ENVIRONMENT, then `uv run --no-sync marimo edit`. They also
# install a notebook bridge wheel into that environment. The environment must
# therefore be a writable virtualenv. It is created over the read-only Nix
# Python with --system-site-packages, so every pre-installed package resolves
# to the store and only per-session additions land in the writable layer.
{
  pkgs,
  lib,
  name,
  python,
  runtime,
  allowPypi,
}:

let
  uid = "1000";
  venv = "/opt/marimohub/venv";
  # Inside the venv, so the kernel uses the venv interpreter and sees the
  # bridge wheel and any session packages; the Nix env's own `marimo`
  # script would bypass them.
  marimoLauncher = pkgs.writeText "marimo" ''
    #!${venv}/bin/python
    import sys
    from marimo._cli.cli import main
    sys.exit(main())
  '';
in
pkgs.dockerTools.streamLayeredImage {
  # `podman load` keeps this name; the tag is the image's Nix output hash.
  name = "localhost/workbench-${name}";

  contents = [
    runtime
    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.caCertificates
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.gitMinimal
    pkgs.uv
  ];

  fakeRootCommands = ''
    mkdir -p opt/marimohub workspace home/marimo tmp etc
    chmod 1777 tmp
    ${python}/bin/python -m venv --system-site-packages --without-pip ./${venv}
    install -m 0755 ${marimoLauncher} ./${venv}/bin/marimo
    cat > etc/passwd <<EOF
    root:x:0:0:root:/root:/bin/sh
    marimo:x:${uid}:${uid}:marimo:/home/marimo:/bin/sh
    EOF
    cat > etc/group <<EOF
    root:x:0:
    marimo:x:${uid}:
    EOF
    chown -R ${uid}:${uid} opt/marimohub workspace home/marimo
  '';

  config = {
    User = "${uid}:${uid}";
    WorkingDir = "/workspace";
    Cmd = [
      "sleep"
      "infinity"
    ];
    Env = [
      "HOME=/home/marimo"
      "PATH=${venv}/bin:/bin:/usr/bin"
      "VIRTUAL_ENV=${venv}"
      "UV_PROJECT_ENVIRONMENT=${venv}"
      "UV_PYTHON=${venv}/bin/python"
      "UV_PYTHON_DOWNLOADS=never"
      "UV_LINK_MODE=copy"
      "MARIMO_SKIP_UPDATE_CHECK=1"
      # marimohub's reference image snapshots the notebook to HTML so the hub
      # can capture it on teardown.
      "_MARIMO_APP_OVERLOAD_AUTO_DOWNLOAD=[html]"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "WORKBENCH_ENVIRONMENT=${name}"
      "WORKBENCH_CLOSURE=${runtime}"
    ]
    # Without PyPI, a notebook dependency missing from the Nix closure fails
    # session setup instead of silently installing an unpinned package.
    ++ lib.optional (!allowPypi) "UV_OFFLINE=1";
    Labels = {
      "org.opencontainers.image.title" = "workbench-${name}";
      "io.marimohub.workbench.environment" = name;
      "io.marimohub.workbench.closure" = "${runtime}";
    };
  };
}
