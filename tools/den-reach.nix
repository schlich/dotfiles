# Which of this repository's Den aspects each host's system and each home
# includes, followed through nested and conditional includes, which hosts a
# delivery deploys to, and each aspect's policy risk. luvus-deliver evaluates
# it against the flake's `den` output (`nix eval FLAKE#den --apply`) to learn
# which hosts a changed file reaches.
den:
let
  hosts = den.hosts.x86_64-linux;
  uniq =
    names:
    builtins.attrNames (
      builtins.listToAttrs (
        map (name: {
          inherit name;
          value = null;
        }) names
      )
    );
  # Den wraps an include that is a function of its context, such as
  # `{ home, ... }: ...`, in an aspect that keeps the function as `__fn`.
  # Apply it when the context has every argument it requires.
  apply =
    ctx: include:
    let
      fn =
        if builtins.isAttrs include && include ? __fn then
          include.__fn
        else if builtins.isFunction include then
          include
        else
          null;
      args = if fn == null then { } else builtins.functionArgs fn;
      required = builtins.filter (arg: !args.${arg}) (builtins.attrNames args);
    in
    if fn == null then
      include
    else if args != { } && builtins.all (arg: ctx ? ${arg}) required then
      # Only the arguments it names: a pattern without `...` rejects others.
      fn (builtins.intersectAttrs args ctx)
    else
      { };
  # The names of the aspects an include brings in, itself among them. Den's
  # own batteries and anonymous wrappers are walked but not named.
  walk =
    ctx: seen: include:
    let
      aspect = apply ctx include;
      name = if builtins.isAttrs aspect then aspect.name or null else null;
      named = name != null && den.aspects ? ${name};
      own = if named then [ name ] else [ ];
    in
    if !(builtins.isAttrs aspect) || (named && builtins.elem name seen) then
      [ ]
    else
      own ++ builtins.concatMap (walk ctx (seen ++ own)) (aspect.includes or [ ]);
  hostOf = home: builtins.elemAt (builtins.split "@" home) 2;
  # The ssh destination a host is reached at, as
  # den/aspects/fleet/deploy-policy.nix gives it to `system-switch HOST`.
  destination =
    name: host:
    if host.deploy.targetHost == null then
      name
    else if host.deploy.sshPort == null then
      host.deploy.targetHost
    else
      "ssh://${host.deploy.targetHost}:${toString host.deploy.sshPort}";
in
{
  systems = builtins.mapAttrs (
    name: host: uniq (walk { inherit host; } [ ] den.aspects.${name})
  ) hosts;
  homes = builtins.mapAttrs (
    name: home:
    let
      host = hosts.${hostOf name};
    in
    uniq (
      walk {
        inherit host;
        home = home // {
          inherit host;
        };
      } [ ] home.aspect
    )
  ) den.homes.x86_64-linux;
  deployed = builtins.filter (name: hosts.${name}.deploy.enable) (builtins.attrNames hosts);
  # The canaries, which deploy main themselves, by the ssh destination a
  # workstation reaches them at, as den/aspects/fleet/deploy-policy.nix
  # names them. A delivery's canary-first mitigation waits for them.
  canaries = builtins.listToAttrs (
    map
      (name: {
        inherit name;
        value = destination name hosts.${name};
      })
      (
        builtins.filter (name: hosts.${name}.policy.autoDeploy && hosts.${name}.deploy.targetHost != null) (
          builtins.attrNames hosts
        )
      )
  );
  # Every host by its ssh destination, for the steps luvus-deliver lists
  # once main has moved.
  destinations = builtins.mapAttrs destination hosts;
  # The risk den/model/policy.nix assigns each aspect, or null for none.
  risks = builtins.mapAttrs (_: aspect: (aspect.meta or { }).risk or null) den.aspects;
}
