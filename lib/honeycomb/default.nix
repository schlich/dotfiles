{ lib }:

# Honeycomb: no collection a person navigates holds more than six members.
# A cell is the centre of a hexagon and its members are the six neighbours,
# so one set of six direction keys reaches every member of every collection,
# and two more keys move in and out of the tree. README.md has the model.
let
  inherit (lib)
    concatMap
    elemAt
    foldl'
    genList
    length
    ;

  abs = n: if n < 0 then -n else n;
  mod = n: m: n - m * (n / m);
in
rec {
  limit = 6;

  # Pointy-top hexagons in axial coordinates: q grows east, r grows
  # south-east. The compass runs clockwise from east.
  compass = [
    "e"
    "se"
    "sw"
    "w"
    "nw"
    "ne"
  ];

  vectors = {
    e = hex 1 0;
    se = hex 0 1;
    sw = hex (-1) 1;
    w = hex (-1) 0;
    nw = hex 0 (-1);
    ne = hex 1 (-1);
  };

  # The six direction keys ring J and K on a staggered keyboard: H and L on
  # the home row, Y and U above, N and M below, all under the right hand.
  # J and K are left for depth.
  keys = {
    w = "h";
    e = "l";
    nw = "y";
    ne = "u";
    sw = "n";
    se = "m";
    inward = "j";
    outward = "k";
  };

  # Select first, then act: a motion moves or extends the selection, and a
  # verb applies to whatever is selected. The base mode has one name
  # everywhere, and Esc returns to it.
  modes = {
    base = "NORMAL";
    extend = "SELECT";
    escape = "Escape";
  };

  origin = hex 0 0;
  hex = q: r: { inherit q r; };
  add = a: b: hex (a.q + b.q) (a.r + b.r);
  scale = k: a: hex (k * a.q) (k * a.r);
  neighbor = direction: a: add a vectors.${direction};
  neighbors = a: map (direction: neighbor direction a) compass;
  distance = a: b: (abs (a.q - b.q) + abs (a.r - b.r) + abs (a.q + a.r - b.q - b.r)) / 2;

  opposite = direction: turn 3 direction;
  # Turn a direction clockwise by sixths of a circle.
  turn =
    sixths: direction: elemAt compass (mod (mod (indexOf direction + sixths) limit + limit) limit);
  indexOf = direction: lib.lists.findFirstIndex (d: d == direction) null compass;

  # The cells at exactly `radius` steps from `centre`, clockwise from east,
  # so ring 1 is the neighbours in compass order.
  ring =
    radius: centre:
    if radius == 0 then
      [ centre ]
    else
      let
        start = add centre (scale radius vectors.e);
        side =
          state: i:
          let
            direction = elemAt compass (mod (i + 2) limit);
            cells = genList (n: add state.at (scale n vectors.${direction})) radius;
          in
          {
            at = add state.at (scale radius vectors.${direction});
            cells = state.cells ++ cells;
          };
      in
      (foldl' side {
        at = start;
        cells = [ ];
      } (genList (i: i) limit)).cells;

  # The centre, then each ring outward: the order to cycle through cells.
  spiral = radius: centre: concatMap (r: ring r centre) (genList (r: r) (radius + 1));

  # The directions to walk from one cell to another, shortest first.
  route =
    from: to:
    if from == to then
      [ ]
    else
      let
        closer =
          best: direction:
          if distance (neighbor direction from) to < distance (neighbor best from) to then
            direction
          else
            best;
        direction = foldl' closer "e" compass;
      in
      [ direction ] ++ route (neighbor direction from) to;

  # Seat up to six members around a centre, in compass order.
  flower =
    members:
    assert lib.assertMsg (
      length members <= limit
    ) "honeycomb: ${toString (length members)} members do not fit around one cell";
    lib.listToAttrs (lib.imap0 (i: member: lib.nameValuePair (elemAt compass i) member) members);

  # A cell is { name, cells ? [ ] }. Follow direction names down from a cell.
  resolve =
    cell: path:
    if path == [ ] then
      cell
    else
      resolve (flower (cell.cells or [ ])).${builtins.head path} (builtins.tail path);

  # Every cell of a tree that holds more than six members.
  crowded =
    cell:
    let
      here = lib.optional (length (cell.cells or [ ]) > limit) {
        inherit (cell) name;
        count = length cell.cells;
      };
    in
    here ++ concatMap crowded (cell.cells or [ ]);

  # How many levels a tree needs to hold `count` leaves six to a cell.
  depth = count: if count <= limit then 1 else 1 + depth ((count + limit - 1) / limit);

  # Compare a census ({ collection = count; }) with the recorded debt.
  # Nothing may pass six unless the baseline records it, and an entry that
  # is paid off must be removed. A recorded collection that grows only
  # warns, until its regrouping lands and removes the entry.
  audit =
    { census, baseline }:
    let
      over = lib.filterAttrs (_: count: count > limit) census;
    in
    {
      new = removeAttrs over (builtins.attrNames baseline);
      grown = lib.filterAttrs (name: count: baseline ? ${name} && count > baseline.${name}) over;
      shrunk = lib.filterAttrs (name: count: baseline ? ${name} && count < baseline.${name}) over;
      paid = removeAttrs baseline (builtins.attrNames over);
    };

  report =
    result:
    let
      section =
        title: entries:
        lib.optionalString (entries != { }) (
          "${title}\n"
          + lib.concatStrings (lib.mapAttrsToList (name: count: "  ${name}: ${toString count}\n") entries)
        );
    in
    section "New collections over ${toString limit} (split them, or group their members):" result.new
    + section "Collections that shrank (lower their entry in lib/honeycomb/baseline.nix):" result.shrunk
    + section "Collections now within ${toString limit} (remove their entry from lib/honeycomb/baseline.nix):" result.paid;

  clean = result: result.new == { } && result.shrunk == { } && result.paid == { };

  # Growth in a collection that was already over six, as one warning line.
  growth =
    result:
    lib.concatStringsSep ", " (
      lib.mapAttrsToList (name: count: "${name} is now ${toString count}") result.grown
    );
}
