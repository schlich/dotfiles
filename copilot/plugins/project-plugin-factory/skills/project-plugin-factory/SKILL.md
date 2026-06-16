---
name: project-plugin-factory
description: Design and scaffold a user-specific or project-specific GitHub Copilot CLI plugin plus companion repo-local prompts and instructions.
---

# Project Plugin Factory

This skill helps design and scaffold a **user-specific or project-specific GitHub Copilot CLI plugin**.

Use it when the user wants a package that:

- installs as a Copilot CLI plugin
- encodes repository-aware agents and skills
- optionally bundles MCP/LSP configuration
- also creates repo-local prompts and instruction files for day-to-day use

## What this skill owns

- selecting the right customization surface for each behavior
- selecting the right host repository for the generated files
- producing a scaffold spec
- generating the file tree for the target plugin
- generating the target repository overlay for prompts and instructions

## What this skill does not do automatically

- it does not invent repository conventions without evidence
- it does not put personal workflow plugins into an arbitrary project repo
- it does not enable hooks unless the user asks for an automatic policy
- it does not create MCP/LSP configs unless the spec includes them

## Workflow

### 1. Analyze the target project

Collect:

- project name and repository URL
- dominant languages and frameworks
- build, test, and lint commands
- recurring workflows worth turning into prompts
- durable conventions worth turning into instructions
- external tools that justify MCP or LSP integration
- whether the customization is user-specific or project-specific
- the repository root that should host the generated files

### Scope routing

Apply these rules before filling the rest of the spec:

| If the customization is... | Host the generated files in... |
| --- | --- |
| your personal workflow, reusable preferences, or cross-repo habits | the dotfiles repo |
| one repository's commands, policy, architecture, or recurring tasks | that project repo |

### 2. Place each concern in the right surface

Use this default mapping:

| If the concern is... | Put it in... |
| --- | --- |
| orchestration across multiple task types | agent |
| reusable bounded execution pattern | skill |
| deterministic file emission | skill script |
| persistent repo guidance | instruction file |
| user-invoked workflow entrypoint | prompt file |
| external tooling integration | MCP/LSP config |
| automatic guardrail | hook |

### 3. Write the scaffold spec

Start from `examples/project-plugin-spec.example.json` and fill in the scope-specific values.

The spec should be concrete enough to generate:

- `plugin.json`
- at least one custom agent
- at least one skill
- optional `.mcp.json`
- optional `lsp.json`
- optional plugin `hooks.json`
- optional `.github/hooks/<name>.json`
- `.github/prompts/use-<pluginName>.prompt.md`
- `.github/instructions/<pluginName>.instructions.md`

### 4. Generate files

Run:

```bash
nu copilot/plugins/project-plugin-factory/skills/project-plugin-factory/scripts/scaffold.nu SPEC_PATH
```

If you are not in this repository, adapt the path to the installed plugin location.

### 5. Review the emitted output

Confirm that:

1. the target plugin is installable on its own
2. prompts and instructions are emitted into the repo overlay, not hidden inside the plugin manifest
3. optional MCP/LSP files only exist when they were explicitly requested
4. the generated agent and skill reflect real project commands and conventions
5. the plugin and overlay were emitted into the correct repository for the chosen scope
6. hook files only exist when they were explicitly requested, and they are placed in the right surface for the chosen policy

## Expected spec fields

See `references/spec-schema.md` for the full list.

Minimum useful fields:

- `customizationScope`
- `projectName`
- `pluginName`
- `description`
- `authorName`

Strongly recommended:

- `projectRepoDir` for project-specific plugins
- `dotfilesRepoDir` for user-specific plugins when it cannot be inferred
- `repositoryUrl`
- `language`
- `buildCommand`
- `testCommand`
- `lintCommand`
- `agentName`
- `skillName`
- `skillDescription`
- `instructionsApplyTo`
- `promptDescription`
- `pluginOutputDir` and `repoOverlayDir` only when overriding the default in-repo placement
- `pluginHooks` for plugin-bundled automatic guardrails
- `repoHooks` for repository-level policy that should also apply in `.github/hooks/`

## Example usage

1. Inspect the target repository.
2. Draft a spec file.
3. Run the scaffold script.
4. Install the emitted plugin with `copilot plugin install`.

## Quality bar

- Prefer a minimal plugin over an overbuilt one.
- Keep generated prose specific and actionable.
- Keep generated commands real and project-relevant.
- Make prompts short entrypoints, not giant policy dumps.
- Make instructions durable and repo-scoped.
- Keep user-specific plugins in the dotfiles repo and project-specific plugins in the project repo.
