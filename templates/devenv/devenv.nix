{ pkgs, ... }:

{
  # https://devenv.sh/packages/
  packages = with pkgs; [
    bat
    difftastic
    fd
    gh
    jujutsu
    nixfmt
    nushell
    prek
    ripgrep
  ];

  # https://devenv.sh/languages/
  # languages.python = {
  #   enable = true;
  #   uv.enable = true;
  # };

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/processes/
  # processes.web.exec = "nu serve.nu";

  # https://devenv.sh/tasks/
  # tasks."app:migrate" = {
  #   exec = "nu scripts/migrate.nu";
  #   before = [ "devenv:processes:web" ];
  # };

  # https://devenv.sh/tests/
  enterTest = ''
    nu --version
    jj --version
  '';
}
