# Command Map

Use these mappings when translating common Unix text-processing habits into Nushell.

| Habit | Prefer In Nushell | Notes |
| --- | --- | --- |
| `jq '.foo'` | `from json | get foo` | Keep JSON structured until output time. |
| `jq 'map(...)'` | `from json | each { ... }` | Use `update` for tables of records. |
| `jq 'select(...)'` | `from json | where ...` | Field access works naturally on records and tables. |
| `sed 's/a/b/'` | `str replace 'a' 'b'` | Add `--regex` when regex is actually needed. |
| `awk '{print $1}'` | `lines | split column ... | get column1` | Name columns when possible. |
| `awk '$3 > 10'` | `... | where column3 > 10` | Parse first, then filter. |
| `cut -d: -f1,3` | `split row ':' | select 0 2` or `split column ':' a b c | select a c` | Prefer named columns when reuse matters. |
| `grep foo` | `find foo` or `where {|x| $x =~ 'foo'}` | Use `find` for substring search in streamed text. |
| `grep -E` | `where {|x| $x =~ 'regex'}` | Regex operator works well after `lines`. |
| `rg foo` | `ls **/* | where type == file | each {|f| open --raw $f.name | lines | where {|line| $line =~ 'foo'}}` | Use Nu traversal and filtering when strict Nu-only behavior is required. |
| `sort` | `sort` or `sort-by column` | Structured sort is usually clearer. |
| `uniq` | `uniq` | For grouped counts, use `group-by` plus `length`. |
| `head -n 10` | `first 10` | |
| `tail -n 10` | `last 10` | |
| `tr '\n' ','` | `str join ','` | Usually after `lines` or list creation. |
| `paste -sd,` | `str join ','` | |

## Preferred Mental Model

1. Parse strings into rows, columns, or records.
2. Transform with table and list operations.
3. Only stringify at the boundary.

## Strict Nu-Only Reminder

- Do not default to `grep` or `rg` if the task can be solved with `open`, `lines`, `find`, `where`, `parse`, `split`, or file traversal in Nu.
- If an external must stay, parse its output into structured data before more work.