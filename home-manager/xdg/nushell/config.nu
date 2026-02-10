use std/util "path add"

$env.config.show_banner = false;

alias lg = lazygit
alias hm = home-manager
alias nrb = sudo nixos-rebuild 
alias nixfmt = nix fmt

def ns [ query?: string ] {
  let q = ($query | default "")
  nix-search-tv print | fzf --preview 'nix-search-tv preview {}' --scheme history --query $q
}

path add "~/.local/bin"
path add "~/.pixi/bin"
path add ($env.HOME | path join ".cargo/bin")
