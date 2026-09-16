{ config, ... }:
{
  den.aspects.gpu-amd = {
    meta = config.myConfig.aspectPolicy.gpu-amd;
    description = "AMD hardware contract; host-local hardware modules retain device facts.";
  };
}
