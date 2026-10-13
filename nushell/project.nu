# Open or focus a project's Niri workspace session; see niri/session.nu.
export def project [dir?: path] {
    ^niri-desk project ($dir | default $env.PWD | path expand)
}
