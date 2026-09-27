# Agent Extension Marketplace Consolidation

The original plan was a private canonical `schlich/skills` repository. The scope is now broader: build a private **agent extension marketplace** that can hold and distribute skills, plugins, agents, templates, MCP/LSP integrations, and composite bundles.

Until that dedicated repository exists, `schlich/dotfiles` is the staging area for portable artifacts and migration metadata.

## Target repository

Provisional name:

```text
schlich/agent-marketplace
```

The name is intentionally broader than `skills`; skills are one package type among several.

## Package model

Every marketplace entry should have one primary kind:

- `skill` — reusable agent instructions/workflows, usually centered on `SKILL.md`
- `plugin` — an installable extension that may bundle skills, agents, hooks, MCP, LSP, commands, or runtime code
- `agent` — a reusable agent/persona/capability configuration
- `template` — scaffold or starter package for projects, prompts, plugins, or workflows
- `integration` — MCP/LSP/tool configuration or adapter
- `bundle` — a curated group of marketplace packages installed together

A package may contain multiple artifact types, but its manifest should identify the primary installation unit.

## Target layout

```text
agent-marketplace/
├── marketplace.nuon
├── README.md
├── packages/
│   ├── token-budget-controller/
│   │   ├── package.nuon
│   │   └── skill/
│   │       └── SKILL.md
│   ├── jj/
│   ├── nushell/
│   ├── metavr/
│   └── ...
├── bundles/
│   ├── terminal-agent/
│   ├── xr-development/
│   └── research-engineering/
├── templates/
├── schemas/
│   └── package.schema.json
├── scripts/
│   ├── catalog.nu
│   ├── install.nu
│   ├── validate.nu
│   └── migrate.nu
└── provenance/
    └── sources.nuon
```

Keep package boundaries explicit. Avoid one global `skills/` directory that makes plugins, bundles, and integrations second-class concepts.

## Marketplace manifest

The top-level `marketplace.nuon` is a discoverable catalog. Each package also owns a `package.nuon`.

A package manifest should eventually support:

```nu
{
  name: "token-budget-controller"
  kind: "skill"
  version: "0.1.0"
  description: "Allocate model compute across rolling usage windows"
  path: "packages/token-budget-controller"
  visibility: "private"
  portability: "portable"
  targets: ["codex" "claude" "copilot" "opencode"]
  provides: ["skill"]
  depends_on: []
  source: {
    repo: "schlich/dotfiles"
    path: ".agents/skills/token-budget-controller"
  }
}
```

The exact schema can evolve; the important constraint is that discovery and installation are data-driven rather than hard-coded.

## Installation adapters

Canonical package contents should be client-neutral where practical. Installer adapters can materialize packages into client-specific locations such as:

```text
.agents/skills/
.codex/skills/
.claude/skills/
.github/skills/
.opencode/skills/
copilot/plugins/
```

Do not fork the canonical content merely because clients use different destination directories. Generate or link thin wrappers where format differences require them.

## Bundles

Bundles let the marketplace express higher-level workflows. Likely initial bundles:

- `terminal-agent` — JJ, Nushell, text processing, async runner, RLM
- `xr-development` — Meta VR CLI, Quest verify-first, VR debugging, IWSDK WebXR, immersive design
- `research-engineering` — research/PBT/benchmarking-oriented packages as they are extracted
- `agent-development` — plugin factory, testing, validation, packaging helpers

Bundles should reference packages by manifest identity rather than copying package contents.

## Portability policy

Classify every discovered artifact as one of:

- `portable` — suitable for canonical marketplace ownership
- `adapter` — thin project/client-specific wrapper around a canonical package
- `project-local` — tightly coupled to one repository and should remain there
- `candidate` — likely portable but dependency inspection is incomplete

Do not migrate project-local assets just to increase marketplace size.

## Current inventory

### Portable / canonical candidates already in dotfiles

- `.agents/skills/jj/SKILL.md`
- `.agents/skills/rlm/SKILL.md`
- `.agents/skills/jj-ci/SKILL.md`
- `.agents/skills/nushell/SKILL.md`
- `.agents/skills/async-command-runner/SKILL.md`
- `.agents/skills/nushell/plugin-builder/SKILL.md`
- `.agents/skills/nushell/text-processing/SKILL.md`
- `.agents/skills/token-budget-controller/SKILL.md`

### Project-local

- `schlich/motif:.opencode/skills/http-nu/SKILL.md`
- `schlich/starfish-projects:.agents/skills/ui-playwright/SKILL.md`
- `schlich/dotfiles:copilot/plugins/jj-flake-vigilance/skills/jj-flake-evolution/SKILL.md`

### Marketplace package candidate, but broader than a skill

- `schlich/dotfiles:copilot/plugins/project-plugin-factory/`

This should migrate as a `plugin` package, preserving its skills, templates, hooks/config support, and scaffolding scripts rather than extracting only its `SKILL.md`.

### Portable candidates needing dependency inspection

- `schlich/nix-observatory:.agents/skills/metavr-cli/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-vr-debug/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-iwsdk-webxr/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-quest-verify-first/SKILL.md`
- `schlich/nix-observatory:.agents/skills/hz-immersive-designer/SKILL.md`
- `schlich/starfish-projects:.codex/skills/storylite-create-story/SKILL.md`

## Migration strategy

1. Inventory package-like artifacts across owned repositories.
2. Classify each as portable, adapter, project-local, or candidate.
3. Create the dedicated private marketplace repository.
4. Move portable artifacts as complete package directories, not isolated markdown files.
5. Preserve provenance and original source SHA/path.
6. Add package manifests and validate them in CI.
7. Replace duplicate project copies with generated adapters or thin wrappers where practical.
8. Add an installer/query CLI once the catalog shape stabilizes.
9. Only then archive or delete redundant standalone repositories/files.

## Product direction

The repository should be useful both as source control and as a real registry:

```text
discover -> inspect -> resolve dependencies -> install -> validate -> update
```

That makes it a personal marketplace first, while keeping the package format clean enough to publish selected packages later without restructuring the entire repository.
