{ ... }:

{
  nixpkgs.config.allowUnfree = true;
  accounts.email.accounts.personal = {
    address = "ty.schlich@gmail.com";
    primary = true;
    realName = "Ty Schlichenmeyer";
  };
  fonts.fontconfig.enable = true;
}
