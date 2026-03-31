use std/util "path add"

$env.config.show_banner = false;
$env.config.buffer_editor = "hx";
$env.config.use_kitty_protocol = true;

alias lg = lazygit
alias hm = home-manager

def --wrapped opencode [...args] {
  let github_token = (do -i { ^gh auth token | str trim } | default "")

  if $github_token == "" {
    ^opencode ...$args
  } else {
    with-env { GITHUB_TOKEN: $github_token } {
      ^opencode ...$args
    }
  }
}

def ns [ query?: string ] {
  let q = ($query | default "")
  nix-search-tv print | fzf --preview 'nix-search-tv preview {}' --scheme history --query $q
}

# const NU_LIB_DIRS = ["~/lib/monurepo"] ++ $NU_LIB_DIRS
