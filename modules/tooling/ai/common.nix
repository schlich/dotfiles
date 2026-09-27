{
  config,
  lib,
  pkgs,
  ...
}:

{
  programs.mcp = {
    enable = true;
    servers = {
      chrome-devtools = {
        command = "npx";
        args = [
          "-y"
          "chrome-devtools-mcp@latest"
        ];
      };
      jj = {
        command = "npx";
        args = [
          "-y"
          "jj-mcp@1.0.8"
        ];
      };
      nix = {
        command = "uvx";
        args = [ "mcp-nixos" ];
      };
      nushell = {
        # Pin the configured Nushell: environments such as Yazelix put an
        # older nu first on PATH, which rejects commands config.nu relies on.
        command = lib.getExe config.programs.nushell.package;
        # The limit must be a filesize on the session stack; nu --mcp ignores
        # it as a process environment string. Past the ~10kb default, a result
        # is replaced by a bare "output truncated" note.
        args = [
          "--config"
          "${pkgs.writeText "nu-mcp-config.nu" "$env.NU_MCP_OUTPUT_LIMIT = 50kb\n"}"
          "--mcp"
        ];
      };
      atuin = {
        command = "atuin";
        args = [ "mcp" ];
      };
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # metavr ships binaries only for macOS and Windows, not Linux.
      metavr = {
        command = "npx";
        args = [
          "-y"
          "metavr"
          "mcp"
          "server"
        ];
      };
    };
  };
}
