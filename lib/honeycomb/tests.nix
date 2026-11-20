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
  testAreasAreTheCentreThenTheCompass = {
    expr = map (area: area.cell) honeycomb.areas;
    expected = [ "centre" ] ++ honeycomb.compass;
  };

  testAreaNamesAndTitlesAreDistinct = {
    expr = map (field: builtins.length (lib.unique (map (area: area.${field}) honeycomb.areas))) [
      "name"
      "title"
    ];
    expected = [
      7
      7
    ];
  };

  testNoSectionIsAbsorbedTwice = {
    expr =
      let
        absorbed = lib.concatMap (area: area.absorbs) honeycomb.areas;
      in
      builtins.length absorbed == builtins.length (lib.unique absorbed);
    expected = true;
  };

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

  testEachAxisIsAPairOfOppositeDirections = {
    expr = lib.mapAttrs (_: ends: honeycomb.opposite ends.plus == ends.minus) honeycomb.axes;
    expected = {
      x = true;
      y = true;
      z = true;
    };
  };

  testTheSixSignedStepsAreTheSixDirections = {
    expr = lib.sort builtins.lessThan (
      lib.concatMap
        (axis: [
          (honeycomb.step axis 1)
          (honeycomb.step axis (-1))
        ])
        [
          "x"
          "y"
          "z"
        ]
    );
    expected = lib.sort builtins.lessThan honeycomb.compass;
  };

  testAxisOfUndoesStep = {
    expr = honeycomb.axisOf (honeycomb.step "z" (-1));
    expected = {
      axis = "z";
      sign = -1;
    };
  };

  testTheDiagonalIsTheLineOfSight = {
    expr = [
      (honeycomb.project {
        x = 1;
        y = 1;
        z = 1;
      })
      (honeycomb.project {
        x = 3;
        y = 1;
        z = 2;
      })
      (honeycomb.project { x = 2; })
    ];
    expected = [
      origin
      (hex 1 1)
      (hex 2 0)
    ];
  };

  testLiftIsTheNearestPointOverACell = {
    expr =
      let
        cells = honeycomb.spiral 3 origin;
        points = map honeycomb.lift cells;
        size = point: lib.foldl' (sum: n: sum + (if n < 0 then -n else n)) 0 (builtins.attrValues point);
      in
      {
        back = map honeycomb.project points == cells;
        steps = map size points == map (honeycomb.distance origin) cells;
      };
    expected = {
      back = true;
      steps = true;
    };
  };

  testRotateHandsEachDimensionToTheNextAxis = {
    expr =
      let
        niri = {
          x = "window";
          y = "workspace";
          z = "monitor";
        };
      in
      {
        once = honeycomb.rotate 1 niri;
        thrice = honeycomb.rotate 3 niri == niri;
      };
    expected = {
      once = {
        z = "window";
        x = "workspace";
        y = "monitor";
      };
      thrice = true;
    };
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
    expected = 10;
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
      terminal.sideways = [ "Alt+S" ];
    };
    expected = [
      "desktop binds sw to Mod+Alt+B, not to N"
      "terminal names a seat, sideways, that does not exist"
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
