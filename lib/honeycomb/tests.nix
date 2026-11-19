{ lib }:
let
  honeycomb = import ./. { inherit lib; };
  inherit (honeycomb)
    hex
    origin
    ;
  cell = name: cells: { inherit name cells; };
  leaves = count: lib.genList (i: cell "leaf${toString i}" [ ]) count;
in
{
  testRingOneIsTheCompass = {
    expr = honeycomb.ring 1 origin;
    expected = map (direction: honeycomb.vectors.${direction}) honeycomb.compass;
  };

  testRingHoldsSixCellsPerStepOfRadius = {
    expr = map (radius: builtins.length (lib.unique (honeycomb.ring radius origin))) [
      1
      2
      3
    ];
    expected = [
      6
      12
      18
    ];
  };

  testEveryRingCellIsAtItsRadius = {
    expr = lib.unique (map (honeycomb.distance (hex 2 (-1))) (honeycomb.ring 3 (hex 2 (-1))));
    expected = [ 3 ];
  };

  testSpiralStartsAtTheCentreAndCoversEachCellOnce = {
    expr = {
      first = builtins.head (honeycomb.spiral 2 origin);
      count = builtins.length (lib.unique (honeycomb.spiral 2 origin));
    };
    expected = {
      first = origin;
      count = 19;
    };
  };

  testOppositeDirectionsCancel = {
    expr = map (
      direction: honeycomb.neighbor (honeycomb.opposite direction) (honeycomb.neighbor direction origin)
    ) honeycomb.compass;
    expected = lib.genList (_: origin) 6;
  };

  testTurnWrapsBothWays = {
    expr = [
      (honeycomb.turn 1 "ne")
      (honeycomb.turn (-1) "e")
      (honeycomb.turn 6 "sw")
    ];
    expected = [
      "e"
      "ne"
      "sw"
    ];
  };

  testRouteIsAShortestWalkThatArrives = {
    expr =
      let
        to = hex 3 (-5);
        walk = honeycomb.route origin to;
      in
      {
        steps = builtins.length walk;
        end = lib.foldl' (at: direction: honeycomb.neighbor direction at) origin walk;
      };
    expected = {
      steps = 5;
      end = hex 3 (-5);
    };
  };

  testDirectionKeysAreDistinct = {
    expr = builtins.length (lib.unique (builtins.attrValues honeycomb.keys));
    expected = 8;
  };

  testResolveFollowsDirectionsDownTheTree = {
    expr =
      (honeycomb.resolve
        (cell "root" [
          (cell "a" [ ])
          (cell "b" [
            (cell "c" [ ])
          ])
        ])
        [
          "se"
          "e"
        ]
      ).name;
    expected = "c";
  };

  testStrayChordsNameEachMismatch = {
    expr = honeycomb.strayChords {
      desktop = {
        w = [
          "Mod+H"
          "Mod+Alt+H"
        ];
        sw = [ "Mod+Alt+B" ];
      };
      terminal.up = [ "Alt+K" ];
    };
    expected = [
      "desktop binds sw to Mod+Alt+B, not to N"
      "terminal names a seat, up, that does not exist"
    ];
  };

  testCrowdedNamesOnlyCellsOverSix = {
    expr = honeycomb.crowded (
      cell "root" [
        (cell "full" (leaves 6))
        (cell "over" (leaves 7))
      ]
    );
    expected = [
      {
        name = "over";
        count = 7;
      }
    ];
  };

  testDepthNeededForACount = {
    expr = map honeycomb.depth [
      6
      7
      36
      37
      167
    ];
    expected = [
      1
      2
      2
      3
      3
    ];
  };

  testAuditSortsEachKindOfDrift = {
    expr = honeycomb.audit {
      census = {
        fine = 6;
        fresh = 7;
        bigger = 10;
        smaller = 8;
        same = 12;
        settled = 4;
      };
      baseline = {
        bigger = 9;
        smaller = 9;
        same = 12;
        settled = 7;
      };
    };
    expected = {
      new.fresh = 7;
      grown.bigger = 10;
      shrunk.smaller = 8;
      paid.settled = 7;
    };
  };
}
