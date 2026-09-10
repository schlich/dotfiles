# Sync after validated main changes

The NixOS configuration enables a local webhook listener for this repository.
It accepts only signed `workflow_run` deliveries for the successful `nix-ci`
workflow on `main`, then runs `jj-ci sync` in the checkout. The listener binds
to loopback; Tailscale Funnel provides the public HTTPS endpoint GitHub needs.

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

Then create or update the repository webhook using the local helper:

```nu
nu /home/schlich/dotfiles/jj/webhook-setup.nu https://asus.<tailnet>.ts.net
```

The helper resolves the secret through SecretSpec and configures only the
`workflow_run` event. The receiver checks GitHub's HMAC-SHA256 signature before
parsing any payload, ignores failed, non-`main`, and unrelated workflow runs,
and acknowledges deliveries before the local sync starts. The service receives
only the `jj-ci-webhook` SecretSpec scope and retries if the keyring session is
not available yet.

Do not use Tailscale Serve for this GitHub hook: Serve is tailnet-only, while
Funnel is the public HTTPS tunnel required for GitHub delivery.
