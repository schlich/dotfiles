# CI build tracing

nix-ci traces every flake check and remote check down to the derivation, so
the time a run spends can be attributed to what it built, substituted, or
looked up, instead of to one opaque `nix-fast-build` step.

## How a trace is made

The `flake-check` action (`.github/actions/flake-check/action.yml`) adds
three steps around the build:

1. **Start the Nix build trace** sets Nix's `json-log-path` through
   `NIX_CONFIG`, so every nix process in the job appends its log events as
   JSON to one file, and starts `tools/ci-trace/collect.py` in the
   background. Nix's events carry no timestamps, so the collector follows
   the file and stamps each activity start, stop, and build phase change as
   it arrives, dropping build log lines and progress updates. It follows a
   plain file rather than a FIFO, so a collector that dies cannot block a
   build.
1. **Summarize the Nix build trace** stops the collector and runs
   `ci-trace.nu convert`, which writes the job summary: the traced window,
   the time before the first build or substitution (mostly evaluation),
   counts of built and substituted paths, and the slowest builds with their
   longest phase.
1. **Upload the Nix build trace** saves `trace.json`, `trace-summary.json`,
   and the stamped `events.tsv` as the `nix-trace-<set>-<check>` artifact
   for 30 days.

Both trace steps run even when the build fails and never fail the check.

`trace.json` is a Chrome trace: open it at <https://ui.perfetto.dev>. Builds
sit on `build N` tracks with their phases (`configurePhase`,
`buildPhase`, ...) nested inside, and substitutions on `substitute N` tracks.

## Reading traces locally

`ci-trace`, installed by `modules/home/ci-trace.nix`, reads the artifacts
through `gh` and caches them under `~/.cache/ci-trace`:

```nu
ci-trace report                              # derivations ranked by build minutes, last 20 runs
ci-trace report --branch luvus/integration --runs 50
ci-trace report --checks                     # checks ranked by median traced window
ci-trace run 39544213605                     # one run's jobs, steps, and Nix traces as one Perfetto trace
```

`report` shows, for each derivation CI built rather than substituted, how
many runs built it, the total and typical time, and which checks did. A
derivation near the top that many runs rebuild is a candidate for a binary
cache, a shared toolchain, or removal from the check.
