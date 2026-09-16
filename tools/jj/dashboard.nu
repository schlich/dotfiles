# Open or focus the JJ dashboard; a supplied path selects that workspace.
def main [directory: path = "/home/schlich/dotfiles"] {
    let location = if ($directory | path type) == "file" { $directory | path dirname } else { $directory }
    let root = (^jj --repository $location root | complete)
    if $root.exit_code != 0 {
        error make { msg: $"Not a JJ workspace: ($directory)" }
    }
    let repository = ($root.stdout | str trim)
    let windows = (^niri msg --json windows | complete)
    if $windows.exit_code == 0 {
        let existing = ($windows.stdout | from json | where app_id == "jj-dashboard")
        if ($existing | is-not-empty) and $directory == "/home/schlich/dotfiles" {
            ^niri msg action focus-window --id ($existing | first | get id)
            return
        }
    }
    ^terminal --class jj-dashboard --directory $repository jjui
}
