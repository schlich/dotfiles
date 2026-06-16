# Project Plugin Spec Schema

The scaffold script reads a JSON spec file. Unknown fields are ignored, so you can extend the record locally.

## Core fields

| Field | Required | Description |
| --- | --- | --- |
| `customizationScope` | no | `project` or `user`; defaults to `project` |
| `projectName` | yes | Human-readable project name |
| `pluginName` | yes | Kebab-case generated plugin name |
| `description` | yes | Generated plugin description |
| `authorName` | yes | Author/team name for `plugin.json` |
| `pluginOutputDir` | no | Output directory override for the generated plugin; must stay inside the selected host repo |
| `repoOverlayDir` | no | Output directory override for generated `.github/prompts` and `.github/instructions`; must stay inside the selected host repo |

## Recommended fields

| Field | Description |
| --- | --- |
| `repositoryUrl` | Source repository URL for the generated plugin metadata |
| `license` | License identifier, defaults to `MIT` |
| `language` | Primary project language |
| `buildCommand` | Primary build command |
| `testCommand` | Primary test command |
| `lintCommand` | Primary lint command |
| `workspaceRoot` | Target workspace root, defaults to `.` |
| `projectRepoDir` | Host repository root for project-specific plugins; defaults to the current working directory |
| `dotfilesRepoDir` | Host repository root for user-specific plugins; defaults to `PROJECT_PLUGIN_FACTORY_DOTFILES_REPO` or the current directory when it matches this dotfiles repo |
| `agentName` | Human-readable generated agent name |
| `agentDescription` | Generated agent description |
| `skillName` | Generated skill directory/name |
| `skillDescription` | Generated skill description |
| `instructionsApplyTo` | Glob for generated instruction file |
| `promptDescription` | Generated prompt description |
| `promptFileName` | Prompt filename override, defaults to `use-<pluginName>.prompt.md` |
| `instructionsFileName` | Instruction filename override, defaults to `<pluginName>.instructions.md` |
| `repoHooksFileName` | Repo hook filename override, defaults to `<pluginName>.json` |

## Optional structured fields

### `keywords`

Array of strings copied into generated `plugin.json`.

### `mcpServers`

Record serialized into the generated plugin's `.mcp.json`. The scaffold writes the file only when this field is present and non-empty.

### `lspServers`

Record serialized into the generated plugin's `lsp.json`. The scaffold writes the file only when this field is present and non-empty.

### `pluginHooks`

Record serialized verbatim into the generated plugin's `hooks.json`. Use this for hooks that should travel with the installable plugin, such as user-specific guardrails.

### `repoHooks`

Record serialized verbatim into the generated repository overlay at `.github/hooks/<repoHooksFileName>`. Use this for repository policy that should also apply to repo-level Copilot usage and cloud agent runs.

### `notes`

Free-form text included in the generated instruction and skill text when present.

## Placement behavior

### `customizationScope: "project"`

The scaffold hosts files in the selected project repository:

- plugin directory default: `<projectRepoDir>/copilot/plugins/<pluginName>`
- overlay directory default: `<projectRepoDir>`

### `customizationScope: "user"`

The scaffold hosts files in the selected dotfiles repository:

- plugin directory default: `<dotfilesRepoDir>/copilot/plugins/<pluginName>`
- overlay directory default: `<dotfilesRepoDir>`

If `dotfilesRepoDir` is omitted, the scaffold tries:

1. `PROJECT_PLUGIN_FACTORY_DOTFILES_REPO`
2. the current working directory, when it looks like this dotfiles repo

If neither applies, the scaffold exits with an error asking for `dotfilesRepoDir`.

## Generated defaults

If omitted, the scaffold uses these defaults:

- `agentName`: `<projectName> Specialist`
- `agentDescription`: `Project specialist for <projectName>`
- `skillName`: `project-workflow`
- `skillDescription`: `Primary workflow for <projectName>`
- `instructionsApplyTo`: `**`
- `promptDescription`: `Use the generated Copilot workflow`
- `promptFileName`: `use-<pluginName>.prompt.md`
- `instructionsFileName`: `<pluginName>.instructions.md`
- `repoHooksFileName`: `<pluginName>.json`
- `license`: `MIT`
- `workspaceRoot`: `.`
