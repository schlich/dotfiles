# The session launcher (Mod+Alt+O; see `session.nu overview`): draws the seven
# areas where their keys sit, lists the Johnny Decimal areas and categories
# from the knowledge base's hubs and the projects in each area's folder, then leaves
# a shell where `project DIR` opens one. Run `overview` to list again.

# The areas by direction, and the key for each direction, written beside this
# script from niri/binds.nix when it is installed (modules/home/files.nix).
const areas_file = path self areas.json

def workspace_snapshot [] {
    let result = (^niri msg --json workspaces | complete)
    if $result.exit_code != 0 {
        print $"Niri workspace query failed: ($result.stderr | str trim)"
        return
    }
    let workspaces = ($result.stdout | from json)
    let output = ($workspaces | where is_focused | get 0?.output)
    let here = ($workspaces | where output == $output)
    if not ($areas_file | path exists) {
        print $"Sessions: ($here | where name != null | get name | str join ', ')"
        return
    }

    # ● is the focused area, ○ one with a workspace, · one not visited yet.
    let seats = (open $areas_file)
    let cell = {|direction|
        let name = ($seats.areas | get $direction)
        let workspace = ($here | where name == $name | get 0?)
        let marker = if $workspace == null { "·" } else if $workspace.is_focused { "●" } else { "○" }
        $"($marker) ($seats.keys | get $direction) ($name)" | fill --width 14
    }
    print "Areas (Mod+Alt+key selects, add Shift to carry the column)"
    print $"         (do $cell nw)(do $cell ne)"
    print $"  (do $cell w)(do $cell centre)(do $cell e)"
    print $"         (do $cell sw)(do $cell se)"
    let others = ($here | where name != null and name not-in ($seats.areas | values))
    if ($others | is-not-empty) {
        print $"  Projects open: ($others | get name | str join ', ')"
    }
}

# The Johnny Decimal system: each area's hub in the knowledge base, with the
# categories its list names ("- 83 Money" or "- [83 Money](83-money.md)").
def system_snapshot [] {
    let root = ($env.KB_ROOT? | default ($env.HOME | path join Research kb))
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

# Projects live in the six area folders at the top of ~ (~/AREA/NAME, a few
# grouped one level deeper, parked ones in ~/AREA/.parked), so the folder
# gives each project its area. A project's knowledge-base note
# (`projects/NAME.md`) may tag it with other workspaces too; those show as
# `+area` beside it.
def project_snapshot [] {
    if not ($areas_file | path exists) {
        return
    }
    print "\nProjects (by area folder)"
    let root = ($env.KB_ROOT? | default ($env.HOME | path join Research kb))
    let notes = (glob $"($root)/projects/*.md" | where ($it | path basename) != "index.md" | each {|note|
        let frontmatter = (open --raw $note | parse --regex '(?s)^---\n(?P<yaml>.*?)\n---' | get 0?.yaml)
        if $frontmatter != null { try { $frontmatter | from yaml | select path workspaces } catch { null } }
    } | compact | each {|note| { name: ($note.path | path basename), workspaces: ($note.workspaces | default []) } })
    # The area each tag points to; notes still carry the tags of the nine
    # places the areas replaced.
    let tag_area = { home: home, shell: home, inbox: home, career: life, personal: life }
    for area in (open $areas_file | get flower | where {|area| $area.folder? != null }) {
        let folder = ($env.HOME | path join $area.folder)
        if not ($folder | path exists) {
            continue
        }
        # `ls` leaves out hidden entries, .parked among them.
        let names = (ls $folder | where ($it.name | path expand | path type) == dir | get name | path basename | sort -i | each {|name|
            let note = ($notes | where name == $name | get 0?)
            let others = if $note == null { [] } else {
                $note.workspaces | each {|tag| $tag_area | get --optional $tag | default $tag } | uniq | where $it != $area.name
            }
            if ($others | is-empty) { $name } else { $"($name) ($others | each { $'+($in)' } | str join ' ')" }
        })
        if ($names | is-not-empty) {
            print $"  ($area.folder): ($names | str join ' · ')"
        }
    }
    print "\n`project AREA/NAME` opens a project session. Mod+Alt+O closes this."
}

def overview [] {
    clear
    workspace_snapshot
    system_snapshot
    project_snapshot
}

overview
