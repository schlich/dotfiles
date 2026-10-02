# Nushell for the MCP server only. 0.115.1 ships rmcp 3.1.0, whose tools/list
# omits the ttlMs and cacheScope that MCP 2026-07-28 requires, so Claude Code
# rejects every tool; 0.116.0 ships rmcp 3.4.0, which sends them. Drop this
# once nixpkgs' nushell reaches 0.116.0. The interactive shell stays on
# nixpkgs' release because 0.116.0 starts more slowly (nushell#19105).
{
  nushell,
  fetchFromGitHub,
  rustPlatform,
}:

nushell.overrideAttrs (
  finalAttrs: _: {
    version = "0.116.0";
    src = fetchFromGitHub {
      owner = "nushell";
      repo = "nushell";
      tag = finalAttrs.version;
      hash = "sha256-xSV4v7VJ3vd39a4hAywjo7hXtwrB598DtMOsYWqfIFA=";
    };
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      name = "nushell-${finalAttrs.version}-vendor";
      hash = "sha256-SL+ARL+fFFy8R3IW6IYPcbS+mAXb+Mzp4v3y5uv7wAI=";
    };
    # Upstream CI ran the long test suite for this tag.
    doCheck = false;
  }
)
