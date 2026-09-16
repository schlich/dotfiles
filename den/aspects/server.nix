{ config, ... }:
{
  den.aspects.server = {
    meta = config.myConfig.aspectPolicy.server;
  };
}
