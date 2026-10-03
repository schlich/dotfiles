# Executable knowledge workbench

A proof of concept for one Markdown file that is at once a readable document,
a typed [IWE](https://github.com/iwe-org/iwe) node, and a
[marimo](https://marimo.io) notebook. The file runs in a Nix environment
named by its own frontmatter. Architecture, upstream findings, and open
questions are in [docs/executable-knowledge.md](../docs/executable-knowledge.md).

```text
workbench/
├── .iwe/                  IWE workspace: config.toml and document schemas
├── knowledge/             the corpus (IWE library root)
│   ├── concepts/          typed definitions
│   ├── investigations/    executable-knowledge-demo.md: IWE node + marimo notebook
│   ├── projects/          includes the investigation (inclusion link)
│   ├── hubs/              plain hub of inclusion links
│   └── notes/             plain Markdown, no frontmatter
├── environments/          NAME.nix → `environment: NAME` in frontmatter
├── python/iwe_bridge/     read-only Python access to IWE through its CLI
├── image.nix              marimohub sandbox image for one environment
├── default.nix            environments, images, manifest, and the CLI
├── workbench.nu           the `workbench` CLI
└── tests/                 round-trip and rendered-output tests
```

## Run it locally

From the repository root:

```nu
nix develop path:.#workbench

# Which Nix environment the demo declares, and its store path and image.
workbench env workbench/knowledge/investigations/executable-knowledge-demo.md

# Edit it in marimo inside that environment (unsandboxed; see below).
workbench edit workbench/knowledge/investigations/executable-knowledge-demo.md

# Execute every cell headlessly and write the derived HTML view.
workbench export workbench/knowledge/investigations/executable-knowledge-demo.md -o demo.html

# Validate IWE schemas, environment names, and every executable document.
workbench check workbench

# Query the graph the notebook uses.
cd workbench
iwe find --filter 'type: investigation' -f json
iwe tree -k projects/executable-knowledge
```

`nix run path:.#workbench -- check workbench` works without the shell.
`workbench edit` runs the kernel as your user with no isolation, exactly like
`marimo edit`. It is for documents you wrote. Run untrusted or agent-written
notebooks through marimohub, where each kernel is a rootless Podman
container.

## Test it

```nu
nix build path:.#checks.x86_64-linux.workbench
```

The check copies this directory into a fresh JJ repository and then:

1. edits the demo through marimo's editor save path, then asserts that the
   IWE frontmatter, prose, headings, and links survive, that IWE still
   validates and resolves its neighbours, and that IWE's own normalization
   leaves marimo's cells unchanged (`tests/roundtrip.py`);
2. asserts `jj diff` shows exactly one changed line in one file;
3. runs `workbench check`;
4. executes the demo headlessly in the `visualization` environment and
   decodes the rendered result: the reactive hit and false-alarm rates, and
   the provenance table that the notebook built by asking IWE about itself
   (`tests/rendered.py`).

## Add an environment

Create `environments/NAME.nix` with a `description` and `python` and `tools`
package functions (see `visualization.nix`), and set `environment: NAME` in a
document's frontmatter. Each environment yields a Python closure, a runtime
(`packages.workbench-image-NAME` is its sandbox image), and a manifest entry.
`workbench check` rejects a document that names an undeclared environment.
Set `allowPypi = true` only to let marimohub install notebook dependencies
missing from the Nix closure. By default the image sets `UV_OFFLINE=1`, so a
missing dependency fails loudly instead of installing an unpinned package.

## Run it on the homelab

The `marimohub` Den aspect (`modules/nixos/workbench-hub.nix`) runs the hub
with `fs` storage in `/var/lib/marimohub`, rootless Podman kernels from these
images, and Tailscale Serve identity. No host includes it yet. To enable it,
add the aspect to the homelab and set the login domain:

```nix
# den/hosts.nix, in den.aspects.homelab.includes
den.aspects.marimohub

# a homelab module
services.marimohub.auth.allowedEmailDomains = [ "gmail.com" ];
```

After the system switch, start `marimohub-serve.service` once Tailscale is
logged in. The hub is then at `https://<homelab>.<tailnet>.ts.net:8443`.
Create a project, then a push-mode Git notebook with `root_path: workbench`
and `entry_notebook: knowledge/investigations/executable-knowledge-demo.md`.
Store its sync URL and token, and publish landed commits with:

```nu
with-env { MARIMOHUB_SYNC_URL: $url, MARIMOHUB_SYNC_TOKEN: $token } {
    workbench sync --repo schlich/dotfiles --root-path workbench
}
```

Pick the `workbench-visualization` image for that notebook (**Change base
image**); the hub does not read the frontmatter `environment` key.
