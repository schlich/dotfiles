# Agent follow-up after successful checks

The NixOS configuration enables a local webhook listener for this repository.
It accepts only signed `workflow_run` deliveries for the successful `nix-ci`
workflow in this repository. A successful pull request run starts a read-only,
ephemeral Codex triage with the PR number, head SHA, and run URL. A successful
push to `main` first runs `ci sync`, then `ci sequence --apply` to restack
stacked, retargeted, and conflicting PRs (see `README.md`), then starts the
same triage against the updated checkout. A failed refresh, such as one that
leaves conflicts for resolution, is logged and does not block the triage. Failed runs, unrelated events, and PR runs without an
associated PR number are ignored. The listener binds to loopback; Tailscale
Funnel provides the public HTTPS endpoint GitHub needs.

The webhook HMAC secret is declared in `modules/secretspec.toml` and stored in
the local Secret Service keyring. Create or rotate it with SecretSpec:

```nu
secretspec set --file /home/schlich/dotfiles/modules/secretspec.toml --provider keyring --reason "Create the local GitHub webhook HMAC" JJ_CI_WEBHOOK_SECRET
secretspec check --file /home/schlich/dotfiles/modules/secretspec.toml --provider keyring --scope jj-ci-webhook --no-prompt --reason "Verify the local webhook secret"
```

The Funnel unit is intentionally not started automatically: Tailscale must be
authenticated interactively first, and a logged-out client should not make a
NixOS activation fail. After activating the configuration, authenticate and
start it once:

```nu
sudo tailscale up
sudo systemctl start jj-ci-webhook-funnel
```

If Tailscale requests Funnel approval, approve it. Find the public URL with:

```nu
tailscale funnel status
```

Then create or update the repository webhook:

```nu
jj-ci-webhook-setup
```

The command derives the Funnel URL from this machine's tailnet name (pass a
base URL to override it), resolves the secret through SecretSpec, and
configures only the `workflow_run` event. Rerun it after rotating the secret.

A user timer runs `jj-ci-webhook-setup check` five minutes after login and
daily afterwards. It sends a desktop notification when Tailscale is logged
out, GitHub has no webhook for this machine's Funnel URL, or GitHub reports
that the last delivery failed. Network or `gh` authentication errors are only
logged to the journal (`journalctl --user --unit jj-ci-webhook-check`).

The receiver checks GitHub's HMAC-SHA256 signature before
parsing any payload, deduplicates completed workflow runs, and acknowledges
deliveries before local work starts. It rejects new work with HTTP 503 when its
bounded queue is full so GitHub can retry. The Codex process runs in read-only
ephemeral mode, receives a minimal event context on stdin, and does not inherit
the webhook HMAC secret. Its report and service status are available in the
systemd journal:

```nu
journalctl --unit jj-ci-webhook --follow
```

The service receives only the `jj-ci-webhook` SecretSpec scope and retries if
the keyring session is not available yet.

Do not use Tailscale Serve for this GitHub hook: Serve is tailnet-only, while
Funnel is the public HTTPS tunnel required for GitHub delivery.
