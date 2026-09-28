def workspace_snapshot [] {
    let result = (^niri msg --json workspaces | complete)
    if $result.exit_code != 0 {
        print $"Niri workspace query failed: ($result.stderr | str trim)"
        return
    }

    print "Niri workspaces"
    $result.stdout
    | from json
    | sort-by -i name
    | each {|workspace|
        let marker = if $workspace.is_focused { "●" } else if $workspace.is_active { "○" } else { " " }
        let name = $workspace.name | default $"workspace-($workspace.idx)"
        print $"  ($marker) ($name)"
    }
}

def project_snapshot [] {
    print "\nProject directories"
    let code = $"($env.HOME)/code"
    let projects = if ($code | path exists) {
        ls $code | where type == dir | get name
    } else { [] }

    if ($projects | is-empty) {
        print "  No directories found in ~/code"
    } else {
        $projects | each {|project| print $"  ($project | path basename)  ($project)" }
    }
    print "\nRun `project <dir>` in the control window to open a project workspace, or switch Niri workspaces."
}

loop {
    clear
    print "PROJECT OVERVIEW  •  refreshes every 10 seconds"
    print "───────────────────────────────────────────────\n"
    workspace_snapshot
    project_snapshot
    sleep 10sec
}
