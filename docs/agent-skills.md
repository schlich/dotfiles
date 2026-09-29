# Agent skill organization policy

Agent skills are versioned instructions and supporting resources that agents
load when a task matches their scope. Organize them so that the same skill can
be developed once, installed selectively, and exposed to the clients and stages
that can use it.

## Design goals

- Keep skill content portable across agent clients wherever their skill format
  permits it.
- Make source, version, provenance, license, and installation scope visible.
- Allow skills to be installed as immutable Nix outputs or consumed directly
  from a checkout when iteration matters.
- Compose user, repository, and task-stage selections without copying skill
  content or turning every installed skill into a global instruction.
- Keep client-specific adapters at the integration boundary; do not fork the
  underlying instructions just to satisfy different discovery paths.

## Source-of-truth boundaries

Use three locations for distinct purposes:

1. **Skill repositories** own reusable skill content and its metadata. A
   dedicated catalog repository is appropriate for a growing set of skills
   that are maintained and released together, especially when bulk installation
   or shared validation is useful. It should have a stable directory per skill
   and a manifest that records the skill's identity, version or source revision,
   license, supported clients, and optional lifecycle tags. Keep unrelated
   application code out of this repository.
1. **Project repositories** own skills that encode local architecture,
   commands, conventions, or access rules. Put these beside the code they
   describe, normally under `.agents/skills/<skill-name>/`. Do not move
   repository-specific knowledge into a global catalog just to make it
   installable.
1. **Configuration repositories** choose sources, pin revisions, select
   profiles, and adapt them to clients. They may include skill trees from
   different parts of a repository or from flake inputs. They should not become
   a second copy of the skill text.

Do not create a separate repository just because a skill exists. Start with a
project-local or personal skill. Extract a skill to a shared catalog when it
has multiple consumers, a release or review boundary of its own, or a real
bulk-distribution need. A bulk installer is a consumer of the catalog, not a
second source of truth.

## Skill layout and metadata

Each installable skill has one directory containing `SKILL.md` and any
resources, scripts, or references it needs. Keep the directory self-contained
and avoid relying on its original parent path. A skill should declare a stable
name and a concise activation description in the format required by its target
clients. Shared metadata may additionally record:

- lifecycle stages such as `discover`, `plan`, `implement`, `verify`, `review`,
  `release`, or `operate`;
- capability tags such as `nix`, `web`, or `incident-response`;
- supported clients and any client-specific adaptation required;
- provenance, version or pinned revision, license, and platform constraints;
- whether it is portable, project-specific, or host-specific.

Metadata is for discovery and selection; it must not replace the client-native
skill instructions. Do not silently rewrite upstream skills during packaging.
Use a small adapter, patch, or maintained fork when adaptation is necessary,
and make that relationship explicit.

## Nix flake interface

Use flake inputs to pin external skill sources. Sources that do not expose Nix
outputs should be declared with `flake = false`; a skill package does not need
to force every upstream source to become a flake. Keep the lock file as the
version pin and keep any subdirectory selection in one shared mapping rather
than repeating it for every client.

Define the normalized `agentSkills` contract as follows:

```nix
agentSkills."<namespace>/<name>" = {
  source = <path-to-complete-skill-directory>;
  metadata = {
    description = "...";
    stages = [ "implement" "verify" ];
    capabilities = [ "nix" ];
    clients = [ "codex" "claude-code" ];
    scope = "portable"; # or project / host
    version = "...";
    license = "...";
  };
  package = <optional-derivation>;
};
```

For a catalog flake, expose a stable `agentSkills` output using this contract.
`source` must point to the complete skill directory and `metadata` must include
the supported values for each required field. `package` may be omitted for
plain text skills or set to a derivation when the skill needs generated or
compiled resources. Also expose built, installable outputs under
`packages.<system>.agent-skills-<name>` when callers need ordinary Nix package
semantics. The package output should contain the complete skill directory in a
predictable path and preserve its metadata.

Treat this as the repository and catalog API, not as a requirement to use
Nix's optional `schemas` flake output. That output can teach compatible Nix
tools how to inspect and validate custom outputs, but it is not yet portable
across all Nix implementations ([the current flake-schemas implementation is
for Determinate Nix](https://github.com/DeterminateSystems/flake-schemas)).
Keep the contract usable by ordinary Nix evaluation and expose package
derivations through the standard `packages` output for portable build commands.

In a consuming flake, allow skill declarations at more than one point in the
tree: central catalog entries, focused flake modules, and project-local skill
directories may all contribute. Require each declaration to conform to the
same contract, then normalize them into one registry before installation.
Discover repository-local skills from explicitly selected `.agents/skills/`
roots, including roots within project subtrees when the project opts in. Do not
scan every nested directory implicitly; explicit roots keep ownership and
inclusion reviewable. Give each skill a stable qualified identity
(for example, `catalog/name` or `project/name`) so same-named skills cannot
silently shadow one another. Make precedence explicit: project overrides are
allowed only when declared; otherwise a duplicate identity is an evaluation
error. Retain the selected source and revision in the resulting registry.

Keep the flake interface deliberately small. A consumer should be able to
select an entry by name and obtain its source, metadata, and optional package;
client installation policy belongs in the consumer's module, not in every
catalog. Do not expose host-specific absolute paths as catalog outputs.

## Installation and visibility

Treat installation and activation as separate choices. Installing a skill
makes its files available; selecting it for a client or stage determines when
the agent sees it. Prefer immutable, read-only Nix outputs for stable shared
skills. Use a checkout path for skills under active development or for local
project knowledge. Avoid copying one skill's content into several client
directories.

Client adapters should map the normalized registry to each client's native
discovery mechanism. Where a client accepts a directory of skills, link or
install the complete skill directory there. Where clients differ in format or
capability, adapt at the edge and document losses or substitutions. Do not
install application-owned, self-mutating configuration as a side effect of
skill installation.

## Composable profiles across the development cycle

Define profiles as named selections, not mutually exclusive skill stores. A
profile can select skills by explicit identity, lifecycle stage, or capability
tag. Compose selections from these scopes, from narrowest to broadest:

1. task or command selection;
1. repository or project selection;
1. user selection;
1. system defaults.

More specific scopes may add skills and may explicitly disable a broader
selection. They should not erase unrelated selections implicitly. Resolve
conflicts by stable identity and declared precedence, and report conflicting
versions or incompatible client requirements instead of picking one
arbitrarily.

Provide useful stage-oriented bundles where they reduce noise: discovery and
planning can emphasize repository maps and design guidance; implementation can
emphasize language and framework skills; verification can select test, review,
and security skills; release and operations can select packaging, deployment,
and incident skills. These are examples, not mandatory fixed phases. A project
may define its own stage names, and users should be able to swap a stage bundle
without replacing the repository's baseline skills.

Keep always-on agent instructions short and broadly applicable. Put procedural
or specialized guidance in on-demand skills so discovery descriptions can
activate it only for relevant work. Do not use lifecycle tags as a substitute
for a clear activation description.

## Adding or changing a skill

When adding a skill:

1. Decide whether its knowledge belongs to a project, a personal collection,
   or a shared catalog.
1. Give it a unique stable identity and a focused activation description.
1. Record provenance and license for imported content; pin external sources in
   the flake lock.
1. Add it to the normalized registry and only the profiles and clients that
   need it.
1. Keep generated, cached, and secret data outside the skill source and Nix
   store inputs.
1. Check that the installed directory is complete and that profile selection
   does not create accidental duplicate names or expose the skill globally.

Bulk installation should be an explicit profile or command that selects a
catalog or collection. It should preserve the catalog's versions and metadata,
and it should not implicitly enable every installed skill in every client.
