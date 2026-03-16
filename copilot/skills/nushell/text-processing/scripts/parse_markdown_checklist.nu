#!/usr/bin/env nu
use lib/github_issue_sync.nu [parse-markdown-checklist]

def main [
  input: string,
  --format: string = 'nuon'
] {
  let rows = (parse-markdown-checklist $input)

  match $format {
    'json' => { $rows | to json }
    'table' => { $rows }
    'nuon' => { $rows | to nuon }
    _ => {
      error make {
        msg: 'invalid --format value'
        details: '--format must be one of: nuon, json, table'
      }
    }
  }
}