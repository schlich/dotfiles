$env.config = {show_banner: false}
$env.config.hooks = ($env.config.hooks? | default {})
$env.config.hooks.pre_prompt = (
    $env.config.hooks.pre_prompt?
    | default []
    | append {||
        let direnv = (/nix/store/q71rzcnj4kpv6pp7alasws5si5dp216c-direnv-2.34.0/bin/direnv export json
        | from json
        | default {})
        if ($direnv | is-empty) {
            return
        }
        $direnv
        | items {|key, value|
            {
                key: $key
                value: (do (
                    $env.ENV_CONVERSIONS?
                    | default {}
                    | get -i $key
                    | get -i from_string
                    | default {|x| $x}
                ) $value)
            }
        }
        | transpose -ird
        | load-env
    }
)
