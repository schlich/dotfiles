$env.config = {
  show_banner: false
  edit_mode: vi
}

$env.ENV_CONVERSIONS = {
  "PATH": {
      from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
      to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
  }
}

$env.PATH = ( $env.PATH | prepend '/Users/tyschlichenmeyer/.nix-profile/bin' | prepend '/Users/tyschlichenmeyer/.cargo/bin' )
