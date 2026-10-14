# Local Nix traces

The `asus` workstation runs `otel-desktop-viewer` on loopback:

- UI: <http://127.0.0.1:8000>
- OTLP/HTTP receiver: <http://127.0.0.1:4318>
- Persistent store: `/var/lib/otel-desktop-viewer/telemetry.duckdb`, capped at 2 GiB

Use `nix-otel` for an explicitly traced invocation, for example
`nix-otel build --no-link path:.`. The wrapper runs the pinned Determinate Nix
3.23.1 CLI and sends traces to the local viewer. The system Nix remains
unchanged. Since its daemon is upstream Nix, traces cover the client-side work
but may omit builds and substitutions performed inside the daemon. Full
daemon-side spans require running a Determinate Nix daemon too.

Traces remain on this machine. The viewer is bound to loopback and its
database is restricted to its dynamic system user. Trace data can include
store paths, fetched URLs, and tails of failed build logs; treat the database
as sensitive.

## Common Nix gotchas

- **Slow evaluation:** inspect the `nix build` root trace and its evaluation
  children. Compare the durations of `EvaluateFlakeDerivationOutput` and
  related evaluation spans before looking at build time.
- **Cache miss or slow substitution:** find `QueryPathInfo` and `Substitute`
  spans and inspect `nix.substituter` and `nix.store.name`. On `Substitute`,
  inspect `nix.build.status`; `NoSubstituters` by itself is a normal cache
  miss, so look for the subsequent build or a failed substitution to
  understand the impact.
- **Failed or slow build:** inspect failed or long `Build` spans, including
  `nix.drv.name`, `nix.build.status`, and `nix.machine` for remote builds.
  Failed spans include the error and may include the tail of the build log.
- **Slow or failing fetch:** inspect `FileTransfer` and its HTTP child spans;
  `url.full`, `http.response.status_code`, and
  `http.request.resend_count` help distinguish a slow transfer from retries
  or an HTTP error.

Remote build dispatch appears on this workstation. Spans from the remote
builder itself require the same Nix telemetry settings and a reachable viewer
endpoint on that machine.

To override the viewer endpoint for a single invocation, set the standard
exporter variable before `nix-otel`:

```nu
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 nix-otel build --no-link path:.
```

For one-command diagnosis, set `NIX_DEBUG_OTEL=1` before `nix-otel` to print
the trace ID, then find that trace in the viewer. Trace export failures do not
fail the Nix command.
