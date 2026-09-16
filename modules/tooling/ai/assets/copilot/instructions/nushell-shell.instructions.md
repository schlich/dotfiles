---
description: 'Always use Nushell instead of bash for shell commands and scripts'
applyTo: '**'
---

# Shell Command Conventions: Use Nushell

Always run shell commands and write scripts using **Nushell (`nu`)**, never bash, sh, zsh, or other POSIX shells.

## Hard Rules

- **Never** use `bash`, `sh`, or `zsh` syntax — no shebangs like `#!/bin/bash`, no `[ ]` tests, no `$(...)` subshells written in bash style.
- **Never** use bash idioms: `&&`/`||` for control flow, `$()`, backticks, `if [ -f ... ]`, `for x in $(...)`, heredocs (`<<EOF`), `export VAR=value`, etc.
- **Always** use `nu` to run shell commands in terminals.
- Scripts must use `.nu` extension and start with `#!/usr/bin/env nu` if they need a shebang.

## Text and Data Processing

Before reaching for `grep`, `sed`, `awk`, `cut`, `sort`, `uniq`, `jq`, or similar Unix tools, **load the `nushell-text-processing` skill** to find the idiomatic Nushell pipeline equivalent.

Common substitutions:

| Bash / Unix tool | Nushell equivalent |
|---|---|
| `grep pattern file` | `open file \| lines \| where { $in =~ "pattern" }` |
| `grep -v pattern` | `where { $in !~ "pattern" }` |
| `sed 's/old/new/'` | `str replace "old" "new"` |
| `awk '{print $2}'` | `split row " " \| get 1` |
| `cut -d: -f1` | `split row ":" \| get 0` |
| `sort \| uniq` | `sort \| uniq` (Nu builtins) |
| `wc -l` | `lines \| length` |
| `jq .field` | `get field` (on structured data) |
| `cat file` | `open file` |
| `find . -name "*.rs"` | `glob **/*.rs` |
| `xargs` | pipe into `each` or `par-each` |

## General Nushell Patterns

- Use structured data pipelines — prefer tables, records, and lists over string manipulation.
- Use `open` to read files (auto-parses JSON, TOML, CSV, etc.).
- Use `ls`, `ps`, `sys` for file system, process, and system information.
- Use `$env.VAR` for environment variables, not `$VAR`.
- Use `do { ... }` for subexpressions, not `$(...)`.
- Check the `nushell` skill for idioms, gotchas (especially `$in` vs parameters), and type signatures.

## When Writing Scripts

- Load the **`nushell` skill** before writing any non-trivial Nu script.
- Load the **`nushell-text-processing` skill** when parsing, filtering, or transforming text/data output from external commands.
- Follow Nu's typed pipeline conventions — declare input/output types in `def` signatures.
