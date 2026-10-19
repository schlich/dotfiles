# jj-graph: the package, whose build runs its lints and tests, and the model
# checks of its Quint specifications. Each sees only the files it needs, so
# an edit elsewhere in the repository rebuilds none of them.
{ lib, pkgs }:

let
  source =
    files:
    lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions files;
    };

  # Quint simulates and model checks with TLC; its wrapper brings the JDK.
  modelTools = [
    pkgs.quint
    pkgs.tlaplus
  ];

  # Simulation must reach a state that violates each witness, or the
  # invariants it guards would pass vacuously: each specification's wide
  # instance, and its witnesses.
  witnesses = {
    "NormalizeWide Normalize.qnt" = [
      "WitnessNeverCyclic"
      "WitnessNeverHoists"
      "WitnessNeverMoves"
      "WitnessNeverForks"
      "WitnessNeverReorders"
      "WitnessNeverMerges"
      "WitnessAnchorsNeverGrow"
    ];
    "SkeletonWide Skeleton.qnt" = [
      "WitnessNeverReuses"
      "WitnessNeverUpdates"
      "WitnessNeverUsesSinks"
      "WitnessNeverDropsAnEdge"
    ];
  };
  witnessChecks = lib.concatStrings (
    lib.mapAttrsToList (
      spec: names:
      let
        parts = lib.splitString " " spec;
        main = lib.elemAt parts 0;
        file = lib.elemAt parts 1;
      in
      ''
        quint run --main=${main} --invariant=Invariants \
          --max-samples=2000 --max-steps=10 --seed=0x6a6a6772 ${file}
        for witness in ${lib.concatStringsSep " " names}; do
          if quint run --main=${main} --invariant="$witness" \
            --max-samples=5000 --max-steps=10 --seed=0x6a6a6772 ${file} >/dev/null; then
            echo "no state of ${main} violates $witness: the invariants it guards pass vacuously" >&2
            exit 1
          fi
        done
      ''
    ) witnesses
  );
in
{
  package = pkgs.rustPlatform.buildRustPackage {
    pname = "jj-graph";
    version = (lib.importTOML ./Cargo.toml).package.version;
    src = source [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
      ./spec
    ];
    cargoLock.lockFile = ./Cargo.lock;

    # The end-to-end properties drive real jj repositories, the conformance
    # test generates traces with Quint, `shapes --run` writes trees out with
    # git and tar, and Graphviz's dot is the oracle for reading DOT.
    nativeCheckInputs = [
      pkgs.jujutsu
      pkgs.git
      pkgs.gnutar
      pkgs.graphviz
      pkgs.clippy
      pkgs.rustfmt
    ]
    ++ modelTools;
    preCheck = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      # Hegel's CI profile replays the same cases every run, and a fixed
      # seed does the same for Quint's traces: a landing gate is
      # reproducible.
      export HEGEL_DEFAULT_PROFILE=ci QUINT_SEED=0x6a6a6772
      cargo fmt --check
      cargo clippy --offline --all-targets -- -D warnings
    '';

    meta = {
      description = "Plan, check, and normalize Jujutsu change graphs against the code's dependency graph";
      license = lib.licenses.mit;
      mainProgram = "jj-graph";
      platforms = [ "x86_64-linux" ];
    };
  };

  # The specifications' tests, a simulation of every invariant, the
  # witnesses, and TLC's exhaustive check of the apply protocol and the
  # skeleton.
  model =
    pkgs.runCommand "jj-graph-model"
      {
        src = source [ ./spec ];
        nativeBuildInputs = modelTools;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        cp "$src"/*.qnt .
        quint test --main=NormalizeExamples Normalize.qnt
        quint test --main=SkeletonExamples Skeleton.qnt
        ${witnessChecks}
        quint verify --backend=tlc --main=ApplyBounded --invariant=Invariants --temporal=Settles Apply.qnt
        quint verify --backend=tlc --main=SkeletonSmall --invariant=Invariants Skeleton.qnt
        touch "$out"
      '';

  # Every graph on three changes over one base, with one symbol and one
  # file, and every order of the plan: about twelve minutes, so it reports
  # after a push instead of gating a landing.
  exhaustive =
    pkgs.runCommand "jj-graph-model-exhaustive"
      {
        src = source [ ./spec ];
        nativeBuildInputs = modelTools;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        cp "$src"/*.qnt .
        quint verify --backend=tlc --main=NormalizeTiny --invariant=Invariants Normalize.qnt
        touch "$out"
      '';
}
