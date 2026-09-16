{ config, ... }:
{
  den.aspects.input-stack = {
    meta = config.myConfig.aspectPolicy.input-stack;
    homeManager = {
      imports = [ ../../modules/programs/input-stack.nix ];
      dotfiles.input.enable = true;
    };
  };
}
