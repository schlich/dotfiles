# The session launcher (Mod+Alt+O; see `session.nu overview`): draws the seven
# areas where their keys sit, lists the Johnny Decimal areas and categories
# from the knowledge base's hubs and ~/Projects by workspace tag, then leaves
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

# Projects live flat in ~/Projects (dotfiles and kb stay at the top of ~ and
# are linked in). Each project's knowledge-base note (`projects/NAME.md`) tags
# it with the workspaces it belongs to, so a project can appear under several.
def project_snapshot [] {
    print "\nProjects (by workspace tag)"
    let root = ($env.KB_ROOT? | default ($env.HOME | path join kb))
    let notes = (glob $"($root)/projects/*.md" | where ($it | path basename) != "index.md" | each {|note|
        let frontmatter = (open --raw $note | parse --regex '(?s)^---\n(?P<yaml>.*?)\n---' | get 0?.yaml)
        if $frontmatter != null { try { $frontmatter | from yaml | select path workspaces } catch { null } }
    } | compact)
    # Each area with the tags it gathers; notes still carry the tags of the
    # nine places the areas replaced.
    let tags = [
        [area tags];
        [home [home shell inbox]]
        [work [work]]
        [research [research]]
        [nix [nix]]
        [ai [ai]]
        [xr [xr]]
        [life [life career personal]]
    ]
    for row in $tags {
        let names = ($notes | where {|note| $row.tags | any {|tag| $tag in $note.workspaces } } | get path | path basename | sort -i)
        if ($names | is-not-empty) {
            print $"  ($row.area): ($names | str join ' · ')"
        }
    }

    # Directories with no note yet: tag them so they show up above.
    let tagged = ($notes | get path | path basename)
    let untagged = (ls ($env.HOME | path join Projects) | where ($it.name | path expand | path type) == dir | get name | path basename | where $it not-in $tagged)
    if ($untagged | is-not-empty) {
        print $"  untagged: ($untagged | sort -i | str join ' · ')"
    }
    print "\n`project NAME` opens a project session. Mod+Alt+O closes this."
}

def overview [] {
    clear
    workspace_snapshot
    system_snapshot
    project_snapshot
}

overview
