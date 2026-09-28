{ ... }:

{
  services.paseo = {
    enable = true;
    user = "schlich";
    group = "users";
    listenAddress = "127.0.0.1";
    port = 6767;
    relay.enable = true;
    inheritUserEnvironment = true;
    settings.daemon.mcp = {
      enabled = true;
      injectIntoAgents = true;
    };
  };
}
