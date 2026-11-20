{
  description = "Honeycomb input group: agent programs";

  inputs = {
    # Build Codex from the fork that contains the execution-tool transcript renderer.
    codex.url = "github:schlich/codex/d0e6fb56b19d";
    # Upstream packages OpenCode 2; nixpkgs still ships 1.x.
    opencode.url = "github:anomalyco/opencode/v2.0.30";
    # Anthropic's official Linux build of Claude Desktop, which nixpkgs lacks.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # Continuum IDE, the user's fork of T3 Code
    # (modules/tooling/ai/clients/continuum-ide.nix)
    continuum-ide.url = "github:schlich/continuum-ide/continuum/game-dev-update";
    # T3 Code 0.1.4, the first release with linked environments and
    # delegate_task, from the nixpkgs commit that packaged it
    # (NixOS/nixpkgs#580444); the locked nixpkgs still ships 0.0.45.
    # modules/tooling/ai/clients/t3code/t3code-package.nix takes only t3code from it.
    nixpkgs-t3code.url = "github:NixOS/nixpkgs/1a1a6e280ff8f744a0bf5e2fb32a1fb1775b54e5";
    paseo.url = "github:getpaseo/paseo/main";
  };

  # `sources` are this group's inputs, with those of the groups inside it,
  # by name; `paths` say where each sits, as `nix flake update` names it.
  outputs =
    inputs:
    let
      own = removeAttrs inputs [ "self" ];
    in
    {
      sources = own;
      paths = builtins.mapAttrs (name: _: name) own;
    };
}
