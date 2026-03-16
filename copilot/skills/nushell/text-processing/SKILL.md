---
name: nushell-text-processing
description: 'Convert bash, sed, awk, grep, jq, cut, sort, uniq, and similar text-processing tasks into Nushell pipelines. Use when writing Nu scripts, translating shell one-liners, parsing external command output, or keeping data structured instead of stringly typed.'
---

# Nushell Text Processing

Use this skill when the task is to solve text-processing or data-shaping problems with Nushell instead of bash glue plus external tools.

## Outcomes

- Produce Nushell code and commands that stay structured as long as possible.
- Replace ad hoc bash pipelines with Nu tables, records, lists, and closures.
- Prefer Nu builtins over `sed`, `awk`, `jq`, `cut`, `tr`, `grep`, `rg`, `sort`, `uniq`, `head`, `tail`, and similar tools when Nu can express the task directly.
- Prefer reusable `.nu` scripts in `scripts/` when the transformation is stateful, multi-step, or easy to get wrong in one shell command.

## When To Use

- Converting bash pipelines or shell snippets into Nushell.
- Writing Nu scripts or helper commands for parsing, filtering, grouping, or formatting text.
- Replacing `jq` with `from json`, `get`, `where`, `each`, `update`, `reduce`, and `to json`.
- Replacing `sed` or `awk` with `str`, `parse`, `split`, `lines`, `where`, `each`, `reduce`, and table operations.
- Turning external command output into structured data before further processing.

## Default Rules

1. Keep data structured. Parse text early and emit plain text late.
2. Prefer Nu builtins before reaching for external Unix text tools.
3. Treat JSON, CSV, TSV, SSV, and tables as structured data, not strings.
4. Use explicit closures and column names rather than positional field assumptions.
5. Handle nulls, missing columns, and external command failures deliberately.

## Procedure

1. Identify the real input and output shapes.
   - Is the input raw text, JSON, CSV, a file, or external command output?
   - Is the output meant to be text, a list, a record, or a table?
2. Choose the parser first.
   - JSON: `from json`, `open`.
   - Delimited text: `from csv`, `from tsv`, `from ssv`.
   - Line-oriented text: `lines`, then `parse`, `split row`, or `split column`.
   - Columnar command output: `detect columns` or `from ssv` after light cleanup.
3. Transform with Nu data operations.
   - Filter: `where`, `find`, `str contains`, `=~`.
   - Map: `each`, `update`, `insert`, `upsert`.
   - Aggregate: `group-by`, `math`, `reduce`, `length`, `uniq`, `sort-by`.
   - Reshape: `select`, `reject`, `rename`, `transpose`, `flatten`.
4. Only convert back to text at the boundary.
   - Use `to json`, `to csv`, `format`, `str join`, or interpolated strings when the consumer actually needs text.
5. Verify the result against the original task.
   - Confirm field names, null handling, sort order, and whether the output should remain structured.

## Decision Points

### Parsing Strategy

- If the source is already structured, keep it structured.
- If the source is line-based but regular, prefer `parse` or `split column` over regex-heavy string slicing.
- If the source is irregular but still textual, use `lines` plus targeted `str` or `parse --regex` operations.

### Replacement Strategy

- `jq` style selection and mapping: use `from json`, `get`, `where`, `each`, `update`, `reduce`, `to json`.
- `sed` style substitution: use `str replace` or `str replace --regex`.
- `awk` style column extraction and row filtering: parse into columns first, then use `where`, `select`, `update`, `math`, `group-by`.
- `cut` style splitting: use `split row`, `split column`, `get`, `select`.
- `sort` and `uniq`: use `sort`, `sort-by`, `uniq`, `group-by`.
- `head` and `tail`: use `first`, `last`, `skip`.
- `grep` and `rg` style filtering on loaded text: use `find`, `where`, `str contains`, `=~`, and path-aware Nu file traversal.

### External Commands

- If an external command is needed, run it as an input producer and immediately parse its output.
- Use `^cmd` when the external name conflicts with a Nu builtin.
- Use `complete` or `do -i { ... } | complete` when stderr or exit codes matter.
- Use Nu redirections such as `o>`, `e>`, `o+e>`, `e>|`, or `o+e>|` instead of bash redirection syntax.

## Quality Checks

- The solution does not shell out to `sed`, `awk`, `jq`, `grep`, or `rg` unless Nu is clearly missing required capability.
- The solution names columns and fields instead of relying on fragile positional text processing.
- JSON and tabular data stay structured until the final output step.
- String interpolation and quoting are correct for paths, regexes, and delimiters.
- Null or missing fields use `?` access and `default` where appropriate.
- External command failures are handled when they affect correctness.
- Reusable multi-step workflows live in `scripts/` with non-interactive interfaces and structured stdout.

## Available Scripts

- `scripts/parse_markdown_checklist.nu` - Parses a heading-scoped Markdown checklist into structured rows.
- `scripts/validate_issue_manifest.nu` - Validates a GitHub issue manifest loaded from `nuon`, JSON, or another format Nu can open.
- `scripts/sync_issue_manifest.nu` - Creates or reuses repository issues, adds them to a GitHub Project, and assigns board fields.
- `scripts/lib/github_issue_sync.nu` - Shared parsing, validation, and GitHub sync functions used by the runnable scripts.

## Script Workflow

Requirements:
- `nu` must be installed.
- `gh` must be installed and authenticated.
- The target repository milestones and project fields must already exist.

Recommended flow:

1. Parse the Markdown into structured rows:

```nu
nu scripts/parse_markdown_checklist.nu HELIX_KEYMAP_TRIAGE.md --format nuon
```

2. Curate or generate a manifest in NUON format. Example file:

```nu
open references/github-issue-manifest.example.nuon
```

3. Validate the manifest before any GitHub mutation:

```nu
nu scripts/validate_issue_manifest.nu references/github-issue-manifest.example.nuon
```

4. Preview the sync without changing GitHub state:

```nu
nu scripts/sync_issue_manifest.nu references/github-issue-manifest.example.nuon --repo schlich/reedline --owner schlich --project-number 2 --dry-run
```

5. Apply the sync only after the dry run looks correct:

```nu
nu scripts/sync_issue_manifest.nu references/github-issue-manifest.example.nuon --repo schlich/reedline --owner schlich --project-number 2
```

## Common Patterns

### JSON Instead of `jq`

```nu
open package.json | get version

'[{"name":"Alice","age":30},{"name":"Bob","age":25}]'
| from json
| where age > 28
| get name
```

### Parse Lines Into Columns

```nu
git log --pretty=%h"|"%s"|"%aN -n 10
| lines
| split column "|" commit subject author
```

### Replace `sed` And `awk`

```nu
open --raw Cargo.toml | str replace --regex 'edition = "2018"' 'edition = "2021"'

ps | where cpu > 5 | select pid name cpu
```

### Aggregate Like `awk` Or `jq`

```nu
open data.json
| get items
| group-by --to-table category
| update items {|row| $row.items.value | math sum }
| rename category total
```

### Why These Scripts Exist

The reliable pattern is parse, manifest, validate, then sync. Keep the Markdown parsing separate from the GitHub mutation step, store the curated work items in NUON, and only then call `gh`. That reduces duplicate issues, mismatched fields, and half-finished project imports.

## References

- Use [command map](./references/command-map.md) for common tool replacements.
- Use [parsing recipes](./references/parsing-recipes.md) for line-oriented, tabular, JSON, and external-command patterns.
