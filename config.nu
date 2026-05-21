use std/util "path add"

$env.config.show_banner = false
$env.config.buffer_editor = "hx"
$env.config.use_kitty_protocol = true;

# $env.BROWSER = "google-chrome-stable"
$env.EDITOR = "hx"
$env.VISUAL = "hx"

# let openai_api_key = (do -i { ^pass show ai/openai | str trim } | default "")
# if $openai_api_key != "" {
#     $env.OPENAI_API_KEY = $openai_api_key
# }

# $env.OPENAI_API_KEY = (open /run/agenix/openai)

let github_token = (do -i { ^gh auth token | str trim } | default "")
if $github_token != "" {
    $env.GITHUB_TOKEN = $github_token
}

alias lg = lazygit
alias hm = home-manager
alias nrb = sudo nixos-rebuild
alias nixfmt = nix fmt

# use completions *

# $env.config.completions.external.completer

# let niri_token_prefix_match = {|query: string, candidate: string|
#     let query_parts = ($query | split row '-' | where {|part| $part != '' })
#     let candidate_parts = ($candidate | split row '-')

#     (($query_parts | length) <= ($candidate_parts | length)) and ($query_parts | enumerate | all {|part|
#         (($candidate_parts | get $part.index | default '') | str starts-with $part.item)
#     })
# }


# def --wrapped opencode [...args] {
#     let github_token = (do -i { ^gh auth token | str trim } | default "")

#     if $github_token == "" {
#         ^opencode ...$args
#     } else {
#         with-env { GITHUB_TOKEN: $github_token } {
#             ^opencode ...$args
#         }
#     }
# }

def ns [query?: string] {
    let q = ($query | default "")
    nix-search-tv print | fzf --preview 'nix-search-tv preview {}' --scheme history --query $q
}

path add "~/.local/bin"
path add "~/.pixi/bin"
path add ($env.HOME | path join ".cargo/bin")
