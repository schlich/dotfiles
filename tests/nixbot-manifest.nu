# The nixbot-app-manifest check: the GitHub App manifest nixbot-register
# registers (modules/nixos/nixbot.nix) asks for exactly the permissions and
# events docs/nixbot.md says nixbot needs, and keeps the App private.
use std/assert

const SECTION = "## What the App may do"

# The tables under SECTION, by the heading of their first column: each row's
# cells, with code spans unwrapped.
def doc-tables [doc: path]: nothing -> record {
  let lines = open --raw $doc | lines
  let start = $lines | enumerate | where item == $SECTION | get index
  if ($start | is-empty) {
    error make --unspanned { msg: $"($doc) has no \"($SECTION)\" section." }
  }
  let section = $lines | skip ($start.0 + 1) | take until {|line| $line starts-with "## " }
  let cells = {|line|
    $line | split row "|" | skip 1 | drop 1 | each { str trim | str trim --char "`" }
  }
  $section
  | chunk-by {|line| $line starts-with "|" }
  | where {|lines| $lines.0 starts-with "|" }
  | reduce --fold {} {|table, tables|
    let heading = do $cells $table.0
    $tables | insert $heading.0 ($table | skip 2 | each {|row| do $cells $row })
  }
}

def main [doc: path, registration: path] {
  let manifest = (open --raw $registration | from json).manifest
  let tables = doc-tables $doc

  let required = $tables.Permission | each {|row| { name: $row.0, access: $row.1 } } | sort-by name
  let asked = $manifest.default_permissions | transpose name access | sort-by name
  assert equal $asked $required "The manifest's permissions differ from docs/nixbot.md"

  let events = $tables.Event | each {|row| $row.0 } | sort
  assert equal ($manifest.default_events | sort) $events "The manifest's events differ from docs/nixbot.md"

  assert equal $manifest.public false "The App must stay private"

  print $"The manifest asks for ($required | length) permissions and ($events | length) events, as docs/nixbot.md says."
}
