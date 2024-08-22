$env.config = {
  show_banner: false
  edit_mode: vi
#   hooks: {
#     pre_prompt: [{ ||
#       if (which direnv | is-empty) {
#         return
#       }

#       direnv export json | from json | default {} | load-env
#     }]
#   }
# }
# $env.EDITOR = 'hx'
# $env.config = ($env.config | upsert hooks.env_change.PWD {
#     [
#         {
#             condition: {|_, after|
#                 ('.venv/bin/activate.nu' | path exists)
#             }
#             code: "overlay use .venv/bin/activate.nu"
#         }
#     ]
# })
}
$env.ENV_CONVERSIONS = {
  "PATH": {
      from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
      to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
  }
}
$env.PATH = ( $env.PATH | prepend '/Users/tyschlichenmeyer/.nix-profile/bin' | prepend '/Users/tyschlichenmeyer/.cargo/bin' )
