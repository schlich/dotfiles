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
  # J and K, inside the ring, step down and up whatever is stacked, and I
  # and O beside them go in and out of a level.
  keys = {
    w = "h";
    e = "l";
    nw = "y";
    ne = "u";
    sw = "n";
    se = "m";
    down = "j";
    up = "k";
    inward = "i";
    outward = "o";
  };

  # The seven areas everything is filed under: home at the centre and six
  # around it, in compass order. Every tool that groups work groups it by
  # these: niri's area workspaces (niri/binds.nix), the knowledge base's
  # hubs, and Claude's sidebar sections (`honeycomb sidebar`). `folder` is
  # the area's directory at the top of $HOME, which holds its projects at
  # ~/FOLDER/NAME (a few grouped one level deeper) and parked ones in
  # ~/FOLDER/.parked; home is ~ itself and has none. `absorbs` names sidebar
  # sections the area took over.
  areas = [
    {
      cell = "centre";
      name = "home";
      title = "Home";
      hub = "index";
      folder = null;
      absorbs = [ "Desktop & terminal" ];
    }
    {
      cell = "e";
      name = "work";
      title = "Work";
      hub = "work";
      folder = "Work";
      absorbs = [ ];
    }
    {
      cell = "se";
      name = "research";
      title = "Research";
      hub = "research";
      folder = "Research";
      absorbs = [ "Knowledge base" ];
    }
    {
      cell = "sw";
      name = "nix";
      title = "Nix";
      hub = "nix";
      folder = "Nix";
      absorbs = [
        "Hosts & Nix"
        "CI & landing"
      ];
    }
    {
      cell = "w";
      name = "ai";
      title = "AI & agents";
      hub = "ai";
      folder = "AI";
      absorbs = [ "Agent tooling" ];
    }
    {
      cell = "nw";
      name = "xr";
      title = "XR";
      hub = "xr";
      folder = "XR";
      absorbs = [ ];
    }
    {
      cell = "ne";
      name = "life";
      title = "Life";
      hub = "personal";
      folder = "Life";
      absorbs = [ "Stuff for friends" ];
    }
  ];

  # Select first, then act: a motion moves or extends the selection, and a
  # verb applies to whatever is selected. The base mode has one name
  # everywhere, and Esc returns to it.
  modes = {
    base = "NORMAL";
    extend = "SELECT";
    escape = "Escape";
  };

  # Given { context = { seat = [ chord ]; }; }, every chord that ends on a
  # key other than its seat's, as a sentence. A direction must mean the same
  # key in every tool.
  strayChords =
    navigation:
    let
      keyOf = chord: lib.toLower (lib.last (lib.splitString "+" chord));
      stray =
        context: seat: chord:
        if !(keys ? ${seat}) then
          [ "${context} names a seat, ${seat}, that does not exist" ]
        else
          lib.optional (
            keyOf chord != keys.${seat}
          ) "${context} binds ${seat} to ${chord}, not to ${lib.toUpper keys.${seat}}";
    in
    lib.concatLists (
      lib.mapAttrsToList (
        context: seats:
        lib.concatLists (
          lib.mapAttrsToList (seat: chords: lib.unique (lib.concatMap (stray context seat) chords)) seats
        )
      ) navigation
    );

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

  # Three axes cross a cell, a third of a turn apart, each a pair of opposite
  # directions. A context's three independent ways to move sit one on each:
  # left and right on x, up and down on y, in and out on z. The tiling is
  # then that three-dimensional space seen along its diagonal, and the six
  # direction keys are its six signed steps.
  axes = {
    x = {
      plus = "e";
      minus = "w";
    };
    y = {
      plus = "nw";
      minus = "se";
    };
    z = {
      plus = "sw";
      minus = "ne";
    };
  };

  # The direction a signed step along an axis takes: `step "y" (-1)` is "se".
  step = axis: sign: if sign >= 0 then axes.${axis}.plus else axes.${axis}.minus;

  # The axis and sign of a direction: `axisOf "ne"` is z, -1.
  axisOf =
    direction:
    lib.findFirst (found: found != null) null (
      lib.mapAttrsToList (
        axis: ends:
        if ends.plus == direction then
          {
            inherit axis;
            sign = 1;
          }
        else if ends.minus == direction then
          {
            inherit axis;
            sign = -1;
          }
        else
          null
      ) axes
    );

  # A point of space as a cell of the tiling. The diagonal (1, 1, 1) is the
  # line of sight, so every point along it lands on the same cell.
  project =
    {
      x ? 0,
      y ? 0,
      z ? 0,
    }:
    add (scale x vectors.e) (add (scale y vectors.nw) (scale z vectors.sw));

  # The point of space over a cell that is fewest steps from the origin.
  lift =
    cell:
    let
      along = builtins.elemAt (lib.sort builtins.lessThan [
        (-cell.q)
        cell.r
        0
      ]) 1;
    in
    {
      x = cell.q + along;
      y = along - cell.r;
      z = along;
    };

  # Turn the view by thirds of a circle, clockwise: whatever moved along one
  # axis now moves along the next, and the same keys reach a different
  # dimension. Three thirds, or none, leave the assignment as it was.
  rotate =
    thirds: assignment:
    lib.mapAttrs' (
      axis: what: lib.nameValuePair (axisOf (turn (2 * thirds) axes.${axis}.plus)).axis what
    ) assignment;

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
