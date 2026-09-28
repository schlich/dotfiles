# Open or focus a project's Niri workspace session; see niri/session.nu.
export def project [dir?: path] {
    ^nu $"($env.HOME)/.config/niri/session.nu" project ($dir | default $env.PWD | path expand)
}
