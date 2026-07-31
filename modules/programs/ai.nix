{ inputs, pkgs, ... }:

{
  programs.claude-code = {
    enable = true;
    enableMcpIntegration = true;
    settings = { };
  };

  programs.codex = {
    enable = true;
    enableMcpIntegration = true;
  };

  programs.mcp = {
    enable = true;
    servers = {
      nix = {
        command = "uvx";
        args = [ "mcp-nixos" ];
      };
      nushell = {
        command = "nu";
        args = [ "--mcp" ];
      };
    };
  };

  programs.opencode = {
    enable = true;
    package = pkgs.nuenv.writeScriptBin {
      name = "opencode";
      script = ''
        def --wrapped main [...args] {
          $env.GITHUB_TOKEN = (^${pkgs.gh}/bin/gh auth token | str trim)
          ^${pkgs.opencode}/bin/opencode ...$args
        }
      '';
    };
    enableMcpIntegration = true;
    skills = {
      jj = ../../copilot/skills/jj;
      marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
      nu = ../../copilot/skills/nushell;
    };
    agents = ../../copilot/agents;
    settings = {
      mcp.github = {
        type = "remote";
        url = "https://api.githubcopilot.com/mcp/";
        enabled = true;
        oauth = false;
        headers.Authorization = "Bearer {env:GITHUB_TOKEN}";
      };
      server.hostname = "localhost";
    };
  };

  programs.github-copilot-cli = {
    enable = true;
    enableMcpIntegration = true;
  };

  programs.agent-skills = {
    enable = true;
    sources.marimo-pair = {
      input = "marimo-pair";
      subdir = "skills";
    };
    sources.marimo-team = {
      input = "marimo-skills";
      subdir = "skills";
    };
    sources.anthropic = {
      input = "anthropic-skills";
      subdir = "skills";
    };
    sources.meta-quest = {
      input = "meta-quest-agentic-tools";
      subdir = "skills";
    };
    skills.enable = [
      "pdf"
      "marimo-pair"
      "anywidget"
      "hz-iwsdk-webxr"
    ];
    targets.copilot.enable = true;
  };
}
