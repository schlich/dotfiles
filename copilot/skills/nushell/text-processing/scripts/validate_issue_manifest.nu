#!/usr/bin/env nu
use lib/github_issue_sync.nu [validate-gh-issue-manifest]

def main [manifest_path: string] {
  let items = (open $manifest_path)
  validate-gh-issue-manifest $items
  | select title milestone status priority size
}