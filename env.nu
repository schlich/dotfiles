let github_token_path = ($env.XDG_RUNTIME_DIR | path join "agenix" "github-token")

if ($github_token_path | path exists) {
  let github_token = (open --raw $github_token_path | str trim)

  $env.GITHUB_PERSONAL_ACCESS_TOKEN = $github_token
  $env.GITHUB_TOKEN = $github_token
}
