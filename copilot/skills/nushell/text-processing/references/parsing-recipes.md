# Parsing Recipes

## Turn Raw Text Into Rows

```nu
some-command | lines
```

Use this when each output line represents one logical record.

## Split Delimited Text Into Columns

```nu
some-command
| lines
| split column ':' key value extra
```

Prefer named columns over generic `column1`, `column2`, and so on.

## Parse With A Template

```nu
cargo search shell --limit 5
| lines
| parse '{crate} = {version} #{description}'
| str trim
```

Use `parse` when the text shape is regular and human-readable.

## Parse With Regex Only When Needed

```nu
'user=alice id=42'
| parse --regex 'user=(?P<user>\w+) id=(?P<id>\d+)'
```

If a simple delimiter or template works, prefer that over regex.

## Read Structured Files Directly

```nu
open package.json
open Cargo.toml
open data.csv
```

Use `open --raw` only when you genuinely need plain text bytes or string processing.

## Parse Space-Aligned Output

```nu
df -h
| str replace 'Mounted on' Mounted_On
| detect columns
```

Alternative:

```nu
df -h
| str replace 'Mounted on' Mounted_On
| from ssv --aligned-columns --minimum-spaces 1
```

## Work With JSON Like Data, Not Strings

```nu
'{"items":[{"name":"a","value":1},{"name":"b","value":2}]}'
| from json
| get items
| where value > 1
```

## Parse External Output Then Aggregate

```nu
git log --pretty=%h"|"%s"|"%aN -n 20
| lines
| split column '|' commit subject author
| group-by --to-table author
| update items {|row| $row.items | length }
| rename author commits
```

## Capture Exit Code And Stderr

```nu
do -i { ^grep needle missing-file.txt } | complete
```

This yields a record containing `stdout`, `stderr`, and `exit_code`.

## Final Output Rules

- For structured output, keep the table or record.
- For machine-readable output, use `to json`, `to csv`, or related formatters.
- For human-readable summaries, use `format`, interpolation, or `str join` at the end.