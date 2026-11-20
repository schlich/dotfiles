{
  description = "Honeycomb input group: building, caching and inspecting Nix";

  inputs = {
    # Numtide's Rust reimplementation of the Nix client, which nixpkgs lacks.
    iets.url = "github:numtide/iets";
    # grpc:// stores: homelab's daemon and every remote host's client plugin.
    nix-grpc-store.url = "github:Mic92/nix-grpc-store";
    nixbot.url = "github:Mic92/nixbot";
    # Which nixpkgs pull requests touch a package and which channels they
    # reached; modules/home/nix/nixpkgs-watch.nix runs it. Not in nixpkgs.
    npr.url = "github:manic-systems/npr";
    gen-inspect.url = "github:sini/gen-inspect";
    # The fork's Rust toolchain requires a newer overlay than its own lockfile.
    rust-overlay.url = "github:oxalica/rust-overlay/a110337465cfb76e3806b81b9db3094c3e6e770a";
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
