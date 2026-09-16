{ config, ... }:
{
  den.aspects.development = {
    meta = config.myConfig.aspectPolicy.development;
  };
}
