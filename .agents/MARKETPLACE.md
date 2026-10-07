# Agent Marketplace Architecture

This is the staging design for a general-purpose private agent-extension marketplace.

## Goals

The marketplace should answer four questions mechanically:

1. What capabilities are available?
2. What does each package install or provide?
3. Which agent clients can consume it?
4. What dependencies and provenance does it have?

The canonical unit is a **package**, not a skill file.

## Package kinds

`skill | plugin | agent | template | integration | bundle`

A package can contain nested skills, scripts, prompts, hooks, schemas, MCP/LSP configuration, binaries, or documentation.

## Discovery

Use `marketplace.nuon` as the top-level index and `package.nuon` inside each package. Nushell is a good fit because the catalog remains human-editable structured data while also being directly queryable:

```nu
open marketplace.nuon
| where kind == "skill"
| where targets has "codex"
| select name description path
```

## Installation

Keep canonical content client-neutral. Installation is an adapter step.

Conceptually:

```text
package
   |
   +--> Codex adapter ------> .codex/skills/...
   +--> generic adapter ----> .agents/skills/...
   +--> Claude adapter -----> .claude/skills/...
   +--> Copilot adapter ----> .github/skills/... / copilot/plugins/...
   +--> OpenCode adapter ---> .opencode/skills/...
```

Adapters should copy, generate, or link the minimum client-specific surface needed.

## Validation

CI should eventually validate:

- manifest schema,
- unique package names,
- declared paths exist,
- dependencies resolve,
- target adapters are known,
- required entrypoints exist for each package kind,
- no accidental absolute/local paths,
- optional smoke tests for executable packages,
- provenance metadata remains traceable.

## Versioning

Start with repository-level history plus an optional semantic `version` field per package. Avoid building a full package manager before there is a real need for independent package releases.

## Publication

Default marketplace visibility is private. Package metadata should nevertheless distinguish `private`, `publishable`, and `public` so selected packages can later be mirrored or released individually.

## First package

`token-budget-controller` is the first explicitly marketplace-oriented package. It begins as a skill but should be allowed to grow into a richer package containing:

- the skill,
- a dashboard/UI reference,
- model/limit adapters,
- tests against synthetic budget traces,
- optional CLI or service logic.

The package abstraction prevents that growth from forcing another repository reorganization.
