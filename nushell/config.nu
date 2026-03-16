use std/util "path add"

$env.config.show_banner = false;
$env.config.use_kitty_protocol = true;

alias lg = lazygit
alias hm = home-manager

def ns [ query?: string ] {
  let q = ($query | default "")
  nix-search-tv print | fzf --preview 'nix-search-tv preview {}' --scheme history --query $q
}

path add "~/.local/bin"
path add "~/.pixi/bin"
path add ($env.HOME | path join ".cargo/bin")

const NU_LIB_DIRS = ["~/lib/monurepo"] ++ $NU_LIB_DIRS
