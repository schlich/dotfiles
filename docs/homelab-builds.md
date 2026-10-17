# Offloading builds to homelab

Use homelab's existing Tangled spindle for full flake checks first. Keep
editing, formatting, quick checks, publication, and landing coordination on
the workstation. Activation remains a separate, explicitly approved action.
Keep local clearance as the default until a fresh spindle run passes.

## Existing infrastructure

- `modules/nixos/tangled-spindle.nix` configures one workflow at a time in a
  10 GiB, six-vCPU NixOS guest with a 96 GiB writable volume.
- `.tangled/workflows/flake-checks.yml` builds all `checks.x86_64-linux`,
  including the primary desktop and headless systems. Homelab itself has an
  evaluation check, not a full system-build check.
- Spindle imports completed guest outputs into the host store. Harmonia
  serves them back to subsequent guests and signs them with the existing
  host-local key. This reuse also preserves completed work from timed-out runs.
- Harmonia answers on the tailnet, and every other host substitutes from it
  and builds on homelab (`homelab-cache-client.nix`,
  `homelab-builder-client.nix`). Imported outputs are unrooted and subject
  to GC; this is a reusable cache, not permanent artifact storage.
- `ci land --clearance spindle` already waits for passing workflows on the
  exact commit being landed. Pushes do not start this repository's workflow.
- homelab imports nixbot, which stays off until `hosts/homelab/nixbot.nix`
  names its GitHub App; [nixbot.md](nixbot.md) has the steps to go live.

## Live findings, 2026-10-02

Read-only inspection reached homelab through OpenSSH on port 2222. Port 22
uses Tailscale SSH and requested a separate authentication check. Automation
that uses ordinary SSH keys should select the configured OpenSSH port.

The host reported eight CPUs, about 15.4 GiB total RAM, about 13.8 GiB
available RAM while idle, and 319 GiB free on its root filesystem. Spindle
was active; Harmonia's socket answered `/nix-cache-info`. An inactive
socket-activated service alone does not indicate a fault.

The Funnel unit had failed at boot with `unexpected state: NoState`, while
the persisted Funnel configuration still proxied HTTPS port 443 to spindle
on loopback port 6555. Its stop command also failed with the obsolete CLI
syntax. The unit now retries startup failures, bounds each attempt, and
explicitly selects HTTPS port 443 for both start and stop. This manages the
existing spindle endpoint; it does not expose the cache.

The newest 30 pipeline records returned by the local spindle API contained
eight cancellations, five failures, and 17 timeouts, ending on September 29.
They do not prove the current configuration passes. Earlier records and
step logs were not inspected, so the counts are not a complete history or
a diagnosis of the build failures.

## First offloaded landing

After the Funnel fix is built and explicitly approved for activation on
homelab:

1. Publish a topic with `ci dispatch` when delivery is requested.
1. Start `flake-checks.yml` on the dispatched commit, as described in
   [Starting a spindle run](#starting-a-spindle-run).
1. Inspect the step logs for that exact commit. Require a passing full check
   set before adopting spindle clearance routinely.
1. Deliver with `ci land --clearance spindle`. If trunk moves and landing
   rewrites the head, start another run for the new commit; clearance for
   the old commit cannot clear the new one.
1. Use `ci park` only after landing succeeds. System activation is separate.

## Starting a spindle run

Pushes never start `flake-checks.yml`, because its `when` accepts only manual
triggers. Tangled's web interface cannot start one either. As of 2026-10-16,
the signed-in pipelines and commit pages on tangled.org have no control for
it. In the pinned `tangled` input, the appview sends
`sh.tangled.ci.triggerPipeline` in only two cases. Retrying an existing
pipeline replays that pipeline's own commit. "Run CI" on a fork-based pull
request sends a `pull_request` trigger, which this workflow ignores.

The spindle accepts the call directly. Its `sh.tangled.ci.triggerPipeline`
procedure, given a `manual` trigger, runs the named workflows at any commit
the knot has. A manual run skips every `when` constraint, so the workflow's
`branch` list does not limit which commits can run. The call needs a
service-auth token from the spindle owner's PDS, issued for the spindle's DID
(`did:web:homelab.tail338351.ts.net`), and the token needs the owner's app
password. The user therefore runs this step; an agent cannot.

Run this from the topic's workspace after `ci dispatch`, while `@` is still
the commit that `ci status` reports as published:

```nu
let pds = "https://tngl.sh"
let spindle = "homelab.tail338351.ts.net"
let password = (input --suppress-output "App password for schlich.tngl.sh: ")
let session = (
  http post --content-type application/json
    $"($pds)/xrpc/com.atproto.server.createSession"
    {identifier: "schlich.tngl.sh", password: $password}
)
let token = (
  http get --headers {Authorization: $"Bearer ($session.accessJwt)"}
    $"($pds)/xrpc/com.atproto.server.getServiceAuth?aud=did:web:($spindle)&lxm=sh.tangled.ci.triggerPipeline"
  | get token
)
let sha = (jj log --no-graph -r @ -T commit_id)
(
  http post --content-type application/json
    --headers {Authorization: $"Bearer ($token)"}
    $"https://($spindle)/xrpc/sh.tangled.ci.triggerPipeline"
    {
      repo: "did:plc:3ta3pjip7mu36b7dnznhoyri"
      trigger: {"$type": "sh.tangled.ci.trigger#manual", sha: $sha}
      workflows: ["flake-checks.yml"]
    }
)
```

The response gives the new pipeline's AT-URI. Its record key is the pipeline
ID in `https://tangled.org/schlich.tngl.sh/dotfiles/pipelines/ID/workflow/flake-checks.yml`.
This call is built from the pinned source and has not yet been run against
homelab. If the spindle refuses it, keep local clearance; spindle clearance
has no other entry point until Tangled adds one.

The workflow limits evaluation to two workers at 3072 MiB each. The local
clearance implementation records that a large Den evaluation may need about
6 GiB. Investigate a fresh run's logs and memory peak before tuning this:
reducing workers and increasing per-worker memory may fit a large individual
evaluation better, but leaves less guest memory for concurrent builds.
Changing to a remote builder alone would leave that evaluation local.

## Next phases

Once the spindle passes reliably, provide private workstation access to
Harmonia and declare its existing signing public key as trusted on the
consumer. Keep the signing secret host-local. Use a tailnet-only endpoint
with an explicit access policy; do not publish this cache through Funnel.
This lets local builds and activation preparation reuse outputs already
built on homelab.

Add direct remote builders only if interactive builds still need offloading.
Use a dedicated daemon-accessible SSH identity and a verified host key,
declare `x86_64-linux` and only supported build features, and let the builder
fetch substitutes itself. The ordinary user's forwarded SSH agent is not
the workstation Nix daemon's credential. Budget direct builds alongside the
10 GiB spindle guest rather than allocating the host's full memory twice.
Represent reusable builder capabilities as typed inventory facts and focused
Den aspects, not hostname conditionals.

See [Nix's distributed-build setup](https://nix.dev/tutorials/nixos/distributed-builds-setup.html),
[Tailscale's Funnel lifecycle](https://tailscale.com/docs/reference/tailscale-cli/funnel),
and [the activation policy](architecture.md).
