# The overview launcher (Mod+O; see `session.nu overview`): lists sessions by
# the Mod+N that reaches them and the projects in ~/code, then leaves a shell
# where `project DIR` opens one. Run `overview` to list again.

def workspace_snapshot [] {
    let result = (^niri msg --json workspaces | complete)
    if $result.exit_code != 0 {
        print $"Niri workspace query failed: ($result.stderr | str trim)"
        return
    }

    # The focused output's workspaces, drawn as the numpad grid Mod+KP_N uses.
    let workspaces = ($result.stdout | from json)
    let output = ($workspaces | where is_focused | get 0?.output)
    let here = ($workspaces | where output == $output)
    let cell = {|index|
        let workspace = ($here | where idx == $index | get 0?)
        let marker = if $workspace == null { " " } else if $workspace.is_focused { "●" } else { " " }
        let name = if $workspace == null { "·" } else { $workspace.name | default "(unnamed)" }
        $"($marker)($index) ($name | str substring 0..<16)" | fill --width 22
    }

    print "Sessions (Mod+KP_N, Mod+Alt+H/J/K/L to step)"
    for row in [[7 8 9] [4 5 6] [1 2 3]] {
        print $"  ($row | each {|index| do $cell $index } | str join ' ')"
    }
    let beyond = ($here | where idx > 9 and name != null)
    if ($beyond | is-not-empty) {
        print $"  Beyond the grid: ($beyond | get name | str join ', ')"
    }
}

def project_snapshot [] {
    print "\nProjects"
    let code = $"($env.HOME)/code"
    let projects = if ($code | path exists) {
        ls $code | where type == dir | get name
    } else { [] }

    if ($projects | is-empty) {
        print "  No directories found in ~/code"
    } else {
        $projects | each {|project| print $"  ($project | path basename)  ($project)" } | ignore
    }
    print "\n`project DIR` opens a project session. Mod+O closes this."
}

def overview [] {
    clear
    workspace_snapshot
    project_snapshot
}

overview
