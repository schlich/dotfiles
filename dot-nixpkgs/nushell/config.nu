$env.config = {
  show_banner: false
  edit_mode: vi
}

$env.PATH = $env.PATH | prepend "/run/current-system/sw/bin" | prepend "/Users/tyschlichenmeyer/.local/bin" | prepend "/usr/local/bin" | prepend "/Users/tyschlichenmeyer/.bun/bin"

