{ config, ... }:
{
  den.aspects.wsl = {
    meta = config.myConfig.aspectPolicy.wsl;
    description = "WSL host contract; add nixos-wsl integration when a WSL host is declared.";
  };
}
