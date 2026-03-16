#!/usr/bin/env nu
use lib/github_issue_sync.nu [sync-gh-issue-manifest]

def main [
  manifest_path: string,
  --repo: string,
  --owner: string,
  --project-number: int,
  --dry-run
] {
  if (($repo | default '' | str trim) == '') {
    error make {
      msg: '--repo is required'
      details: 'Example: --repo schlich/reedline'
    }
  }

  if (($owner | default '' | str trim) == '') {
    error make {
      msg: '--owner is required'
      details: 'Example: --owner schlich'
    }
  }

  let items = (open $manifest_path)
  sync-gh-issue-manifest $items $repo $owner $project_number --dry-run=$dry_run
}