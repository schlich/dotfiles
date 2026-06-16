# Project Plugin Factory

`project-plugin-factory` is a meta-plugin for GitHub Copilot CLI. It helps you **design** and **scaffold** either:

- a **user-specific** Copilot plugin for your personal workflow, hosted in this dotfiles repo
- a **project-specific** Copilot plugin, hosted in the target project repo

It also generates the **repo-local overlays** that a plugin cannot bundle directly.

## Why this exists

The Copilot CLI plugin manifest can load:

- custom agents
- skills
- hooks
- MCP server configs
- LSP server configs

It does **not** directly load prompt files or instruction files from `plugin.json`. Those work best as repository-local overlays such as `.github/prompts/` and `.github/instructions/`.

This plugin therefore splits responsibilities deliberately:

| Concern | Best home | Why |
| --- | --- | --- |
| Cross-cutting project orchestration | Custom agent | Good for multi-step reasoning and component selection |
| Repeatable bounded capability | Skill | Good for reusable execution playbooks and script-backed actions |
| File generation | Skill script | Deterministic scaffold output belongs in code, not prose |
| Persistent repository behavior | Instruction files | Durable conventions and routing guidance |
| Human-invoked workflows | Prompt files | Low-friction repeatable entrypoints |
| External tooling | MCP/LSP config | Explicit tool attachment, kept optional |
| Automatic guardrails | Hooks | Only when an org really wants automatic interception |

## Recommendation on placement

Keep this meta-plugin **in this repository** for now:

1. It can be installed directly from a local path or repository subdirectory.
2. It can dogfood the repo's existing Copilot conventions and Nushell-based scripting.
3. It avoids creating a second repository before the workflow stabilizes.

Move it to a **separate repository** only when at least one of these becomes true:

1. You want marketplace publishing or independent versioning.
2. Multiple repositories need the same meta-plugin without depending on this dotfiles repo.
3. The generated templates begin to diverge by organization or language family.

Do **not** split this into multiple plugins yet. Start with:

1. **One factory plugin**: reusable design + scaffold logic.
2. **Generated user-specific or project-specific plugin**: the actual plugin for the target repo.
3. **Generated repo overlay**: `.github/prompts/` and `.github/instructions/` for that same target repo.

Split later only if you need separate language packs or separate marketplace distribution.

## Contents

- `agents/project-plugin-architect.agent.md` — the orchestration agent
- `skills/project-plugin-factory/` — design rubric, scaffold workflow, and Nushell generator script
- `templates/generated-plugin/` — files emitted into the target plugin
- `templates/generated-repo/` — repo-local prompts and instructions emitted for the selected host repo

## Install

Direct installs still work today, but Copilot CLI now warns that marketplace installs are the long-term path. This repository therefore also includes `.github/plugin/marketplace.json`.

### Local path

From this repository root:

```bash
copilot plugin install ./copilot/plugins/project-plugin-factory
```

Or from GitHub by subdirectory:

```bash
copilot plugin install schlich/dotfiles:copilot/plugins/project-plugin-factory
```

### Marketplace from this repository

```bash
copilot plugin marketplace add .
copilot plugin install project-plugin-factory@schlich-dotfiles
```

## Use

1. Use the **Project Plugin Architect** agent or the `project-plugin-factory` skill to design the target plugin.
2. Create a spec file from `examples/project-plugin-spec.example.json`.
3. Run the scaffold script:

```bash
nu copilot/plugins/project-plugin-factory/skills/project-plugin-factory/scripts/scaffold.nu \
  copilot/plugins/project-plugin-factory/skills/project-plugin-factory/examples/project-plugin-spec.example.json
```

The script emits two trees:

- the installable target plugin
- the target repository overlay containing prompts and instructions

## Scope-aware placement

The scaffold resolves output paths from the spec instead of assuming everything belongs in the current working directory.

### User-specific plugin

Use `customizationScope: "user"` when the plugin captures your personal workflow, reusable preferences, or cross-repo orchestration habits.

Default placement:

- plugin: `<dotfilesRepoDir>/copilot/plugins/<pluginName>`
- prompt overlay: `<dotfilesRepoDir>/.github/prompts/use-<pluginName>.prompt.md`
- instruction overlay: `<dotfilesRepoDir>/.github/instructions/<pluginName>.instructions.md`

`dotfilesRepoDir` can be provided in the spec. If omitted, the scaffold will try `PROJECT_PLUGIN_FACTORY_DOTFILES_REPO`, then the current working directory when it looks like this dotfiles repo.

### Project-specific plugin

Use `customizationScope: "project"` when the plugin depends on a single repository's commands, structure, or policy.

Default placement:

- plugin: `<projectRepoDir>/copilot/plugins/<pluginName>`
- prompt overlay: `<projectRepoDir>/.github/prompts/use-<pluginName>.prompt.md`
- instruction overlay: `<projectRepoDir>/.github/instructions/<pluginName>.instructions.md`

`projectRepoDir` defaults to the current working directory when omitted.

Explicit `pluginOutputDir` and `repoOverlayDir` overrides are still supported, but they must stay inside the selected host repository for the chosen scope.

## Output shape

Given a spec, the scaffold produces:

```text
<hostRepoDir>/copilot/plugins/<pluginName>/
├── plugin.json
├── agents/
│   └── project-specialist.agent.md
├── skills/
│   └── project-workflow/
│       └── SKILL.md
├── .mcp.json         # only if spec defines MCP servers
└── lsp.json          # only if spec defines LSP servers

<hostRepoDir>/
└── .github/
    ├── prompts/
    │   └── use-<pluginName>.prompt.md
    └── instructions/
        └── <pluginName>.instructions.md
```

## Design rules baked into the scaffold

1. Keep the generated plugin small and portable.
2. Put project policy and dispatching guidance in instructions, not in the plugin manifest.
3. Use prompts as entrypoints for repeatable human-invoked workflows.
4. Use skills for deterministic or semi-deterministic actions that can be script-backed later.
5. Only add MCP/LSP config if the target project already benefits from those tools.
6. Avoid hooks unless there is a clear automatic policy worth enforcing.
7. Keep personal workflow plugins in the dotfiles repo and repository policy plugins in the project repo.
