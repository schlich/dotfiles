$env.config = {
  show_banner: false
  edit_mode: vi
}

$env.PATH = $env.PATH | prepend "/Users/tyschlichenmeyer/.local/bin"
$env.PATH = $env.PATH | prepend "/usr/local/bin"
$env.PATH = $env.PATH | prepend "/Users/tyschlichenmeyer/starlake"
$env.PATH = $env.PATH | prepend "/Users/tyschlichenmeyer/.bun/bin"
