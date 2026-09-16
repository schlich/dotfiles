# `pair`: a small Nushell code-mode runtime

`pair` uses Nushell's stock MCP server (`nu --mcp`) as the agent transport and
keeps code-mode state on disk in `.pair/`. Scratch evaluation stores the code
and its typed result as NUON. Promotion is the explicit boundary at which code
is copied into `.pair/units/`; runs are recorded separately.

The first lifecycle is:

```text
EMPTY -> SCRATCH_RESULT -> MANAGED_UNIT -> VALID/INVALID -> EXECUTION_RESULT
```

The graph already has explicit `inputs`, `outputs`, `depends_on`, and `effects`
fields so invalidation and effect policy can be added without parsing prose.
No JJ mutation is performed by this runtime; promoted source and intentional
state can be reviewed with `jj diff`.

Example:

```nu
pair eval 'ls | where type == file | select name size | sort-by size --reverse'
pair inspect scratch-... schema
pair promote scratch-... largest-files
pair check
pair run largest-files
pair status
```
