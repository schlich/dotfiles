let
  user = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMx2f7+EO5QZSBDIGw6iyPDGG/aoYx6KIEDoEHjIv/T4 nixos@nixos";
  host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFA2Wd/hVlqxzgbbJS6ogkbMDj0Anq4xlMKLPKDdvmAs root@nixos";
in
{
  "secrets/github-token.age".publicKeys = [
    user
    host
  ];
}
