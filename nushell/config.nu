$env.config = ( $env.config? | default {
    show_banner: false
    edit_mode: vi
} )
$env.config.hooks = ($env.config.hooks? | default {})
# $env.config.hooks.pre_prompt = (
#     $env.config.hooks.pre_prompt?
#     | default []
#     | append {||
#         let direnv = (/nix/store/q71rzcnj4kpv6pp7alasws5si5dp216c-direnv-2.34.0/bin/direnv export json
#         | from json
#         | default {})
#         if ($direnv | is-empty) {
#             return
#         }
#         $direnv
#         | items {|key, value|
#             {
#                 key: $key
#                 value: (do (
#                     $env.ENV_CONVERSIONS?
#                     | default {}
#                     | get -i $key
#                     | get -i from_string
#                     | default {|x| $x}
#                 ) $value)
#             }
#         }
#         | transpose -ird
#         | load-env
#     }
# )

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
$env.ENV_CONVERSIONS = {
    "PATH": {
        from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
        to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
    }
    "Path": {
        from_string: { |s| $s | split row (char esep) | path expand --no-symlink }
        to_string: { |v| $v | path expand --no-symlink | str join (char esep) }
    }
}
$env.PATH = $env.PATH | prepend '/Users/tyschlichenmeyer/.nix-profile/bin' | prepend '/Users/tyschlichenmeyer/.cargo/bin'
