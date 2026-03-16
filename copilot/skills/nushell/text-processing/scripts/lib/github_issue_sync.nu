export def parse-markdown-checklist [path: string] {
  open --raw $path
  | lines
  | reduce -f {phase: null, mode: null, section: null, rows: []} {|line, state|
      if ($line | str starts-with '## Phase ') {
        $state | upsert phase ($line | str replace '## ' '')
      } else if ($line | str starts-with '### ') {
        $state | upsert mode ($line | str replace '### ' '')
      } else if ($line | str starts-with '#### ') {
        $state | upsert section ($line | str replace '#### ' '')
      } else if ($line | str starts-with '- [ ] ') {
        let parsed = (
          $line
          | parse --regex '^- \[ \] `(?<binding>[^`]+)` -> `(?<action>[^`]+)`: (?<notes>.*)$'
        )

        if ($parsed | is-empty) {
          $state
        } else {
          let row = (
            $parsed
            | first
            | insert phase $state.phase
            | insert mode $state.mode
            | insert section $state.section
          )

          $state | update rows {|rows| $rows | append $row }
        }
      } else {
        $state
      }
    }
  | get rows
}

export def parse-markdown-table [path: string] {
  let lines = (
    open --raw $path
    | lines
    | where {|line| ($line | str trim | str starts-with '|') }
    | where {|line| not (($line | str replace -a '|' '' | str trim) =~ '^[-: ]+$') }
  )

  let header = (
    $lines
    | first
    | split row '|'
    | where {|cell| ($cell | str trim) != '' }
    | each {|cell|
        $cell
        | str trim
        | str downcase
        | str replace -a ' ' '_'
      }
  )

  $lines
  | skip 1
  | each {|line|
      let cells = (
        $line
        | split row '|'
        | where {|cell| ($cell | str trim) != '' }
        | each {|cell| $cell | str trim }
      )

      $header
      | enumerate
      | reduce -f {} {|col, row|
          $row | upsert $col.item ($cells | get $col.index)
        }
    }
}

export def validate-gh-issue-manifest [items] {
  let required = [title body milestone status priority size]

  let missing = (
    $items
    | enumerate
    | each {|row|
        let missing_fields = (
          $required
          | where {|name|
              (($row.item | get -o $name | default '' | into string | str trim) == '')
            }
        )

        if ($missing_fields | is-empty) {
          null
        } else {
          {
            row: ($row.index + 1)
            title: ($row.item | get -o title | default '')
            missing: $missing_fields
          }
        }
      }
    | compact
  )

  if not ($missing | is-empty) {
    error make {
      msg: 'manifest has missing required fields'
      details: ($missing | to nuon)
    }
  }

  let duplicates = (
    $items
    | group-by title
    | transpose title rows
    | where {|group| ($group.rows | length) > 1 }
    | get title
  )

  if not ($duplicates | is-empty) {
    error make {
      msg: 'manifest contains duplicate issue titles'
      details: ($duplicates | str join ', ')
    }
  }

  $items
}

export def milestone-map [repo: string] {
  ^gh api -X GET $'repos/($repo)/milestones?state=all&per_page=100'
  | from json
  | reduce -f {} {|milestone, acc|
      $acc | upsert $milestone.title $milestone.number
    }
}

export def single-select-options [fields, field_name: string] {
  $fields.fields
  | where name == $field_name
  | first
  | get options
  | reduce -f {} {|opt, acc| $acc | upsert $opt.name $opt.id }
}

export def project-field-maps [project_number: int, owner: string] {
  let fields = (^gh project field-list $project_number --owner $owner --format json | from json)

  {
    project_id: (^gh project view $project_number --owner $owner --format json | from json | get id)
    status_field_id: ($fields.fields | where name == 'Status' | first | get id)
    priority_field_id: ($fields.fields | where name == 'Priority' | first | get id)
    size_field_id: ($fields.fields | where name == 'Size' | first | get id)
    status_options: (single-select-options $fields 'Status')
    priority_options: (single-select-options $fields 'Priority')
    size_options: (single-select-options $fields 'Size')
  }
}

export def existing-gh-issues [repo: string] {
  ^gh api -X GET $'repos/($repo)/issues?state=all&per_page=100'
  | from json
  | where pull_request? == null
  | reduce -f {} {|issue, acc| $acc | upsert $issue.title $issue }
}

export def existing-project-items [owner: string, project_number: int] {
  let query = $'query { user(login: "($owner)") { projectV2(number: ($project_number)) { items(first: 100) { nodes { id content { __typename ... on Issue { title url } } } } } } }'

  ^gh api graphql -f $'query=($query)'
  | from json
  | get data.user.projectV2.items.nodes
  | where {|node| (($node.content | get -o __typename | default '') == 'Issue') }
  | reduce -f {} {|node, acc|
      $acc | upsert $node.content.title {id: $node.id, url: $node.content.url}
    }
}

export def sync-gh-issue-manifest [items, repo: string, owner: string, project_number: int, --dry-run] {
  let items = (validate-gh-issue-manifest $items)
  let milestones = (milestone-map $repo)
  let fields = (project-field-maps $project_number $owner)
  let existing_issues = (existing-gh-issues $repo)
  mut existing_items = (existing-project-items $owner $project_number)
  mut results = []

  for item in $items {
    let existing_issue = ($existing_issues | get -o $item.title)

    let issue_url = if ($existing_issue == null) {
      if $dry_run {
        $'dry-run://issues/($item.title | str replace -a " " "-")'
      } else {
        ^gh api -X POST $'repos/($repo)/issues' -f $'title=($item.title)' -f $'body=($item.body)' -F $'milestone=($milestones | get $item.milestone)'
        | from json
        | get html_url
      }
    } else {
      $existing_issue.html_url
    }

    let existing_item = ($existing_items | get -o $item.title)

    let item_id = if ($existing_item == null) {
      if $dry_run {
        $'dry-run-item-($item.title | str replace -a " " "-")'
      } else {
        ^gh project item-add $project_number --owner $owner --url $issue_url --format json
        | from json
        | get id
      }
    } else {
      $existing_item.id
    }

    if (not $dry_run) {
      ^gh project item-edit --id $item_id --project-id $fields.project_id --field-id $fields.status_field_id --single-select-option-id ($fields.status_options | get $item.status) | ignore
      ^gh project item-edit --id $item_id --project-id $fields.project_id --field-id $fields.priority_field_id --single-select-option-id ($fields.priority_options | get $item.priority) | ignore
      ^gh project item-edit --id $item_id --project-id $fields.project_id --field-id $fields.size_field_id --single-select-option-id ($fields.size_options | get $item.size) | ignore
    }

    $results = ($results | append {
      title: $item.title
      milestone: $item.milestone
      status: $item.status
      priority: $item.priority
      size: $item.size
      issue_url: $issue_url
      project_item_id: $item_id
      dry_run: $dry_run
    })

    $existing_items = ($existing_items | upsert $item.title {id: $item_id, url: $issue_url})
  }

  $results
}