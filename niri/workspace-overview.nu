# The session launcher (Mod+0; see `session.nu overview`): lists sessions by
# the Mod+<digit> that reaches them, the Johnny Decimal areas and categories from
# the knowledge base's hubs, and the projects in ~'s area directories, then leaves a shell
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

# The Johnny Decimal system: each area's hub in the knowledge base, by the
# Mod+<digit> that reaches it, with the categories its list names ("- 83 Money" or
# "- [83 Money](83-money.md)").
def system_snapshot [] {
    let root = ($env.KB_ROOT? | default ($env.HOME | path join kb))
    let hubs = (glob $"($root)/[0-9][0-9]-[0-9][0-9]-*.md" | sort)
    if ($hubs | is-empty) {
        return
    }
    print "\nSystem (Mod+N: this area's notes, Mod+Shift+N: capture to today)"
    for hub in $hubs {
        let lines = (open --raw $hub | lines)
        let title = ($lines | where ($it | str starts-with "# ") | get 0? | default ($hub | path basename) | str replace "# " "")
        let categories = ($lines | parse --regex '^- \[?(?P<id>\d\d) (?P<name>[^\]]+)' | each {|category| $"($category.id) ($category.name)" })
        let listed = if ($categories | is-empty) { "" } else { $": ($categories | str join ' · ')" }
        print $"  ($title | str substring 0..0) ($title)($listed)"
    }
}

# Projects live in the Johnny Decimal area directories of ~ ("40-49 Nix tooling/nix-ui")
# and their categories ("70-79 Career/77 Gig & contract work/resume"); a numbered
# subdirectory is a category, anything else a project.
def project_snapshot [] {
    print "\nProjects"
    let areas = (ls $env.HOME | where type == dir and ($it.name | path basename) =~ '^\d\d-\d\d ' | get name | sort)
    let listings = ($areas | each {|area|
        # Projects that must stay at the top of ~ (dotfiles, kb) are linked in.
        let entries = (ls ($area | into glob) | get name | where ($it | path expand | path type) == dir)
        let categories = ($entries | where ($it | path basename) =~ '^\d\d ')
        let nested = ($categories | each {|category| ls ($category | into glob) | where type == dir | get name } | flatten)
        {area: ($area | path basename), projects: ($entries | where $it not-in $categories | append $nested)}
    } | where ($it.projects | is-not-empty))

    if ($listings | is-empty) {
        print "  No projects found in the area directories of ~"
    } else {
        $listings | each {|listing|
            print $"  ($listing.area): ($listing.projects | each { path basename } | str join ' · ')"
        } | ignore
    }
    print "\n`project \"AREA/NAME\"` opens a project session. Mod+0 closes this."
}

def overview [] {
    clear
    workspace_snapshot
    system_snapshot
    project_snapshot
}

overview
