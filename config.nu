use std/util "path add"

$env.config.show_banner = false


alias lg = lazygit
alias hm = home-manager
alias nrb = sudo nixos-rebuild --flake /home/nixos/dotfiles#asus
alias nixfmt = nix fmt

# source ~/.config/nushell/completions/niri.nu
# use completions *

# $env.config.completions.external.completer

# let niri_token_prefix_match = {|query: string, candidate: string|
#     let query_parts = ($query | split row '-' | where {|part| $part != '' })
#     let candidate_parts = ($candidate | split row '-')

#     (($query_parts | length) <= ($candidate_parts | length)) and ($query_parts | enumerate | all {|part|
#         (($candidate_parts | get $part.index | default '') | str starts-with $part.item)
#     })
# }

def ns [query?: string] {
    let q = ($query | default "")
    nix-search-tv print | fzf --preview 'nix-search-tv preview {}' --scheme history --query $q
}

# path add "~/.local/bin"
# path add "~/.pixi/bin"
# path add ($env.HOME | path join ".cargo/bin")
