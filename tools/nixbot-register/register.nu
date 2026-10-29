# nixbot-register: create nixbot's GitHub App from the manifest in
# modules/nixos/nixbot.nix and write what turning nixbot on needs into this
# checkout: the App's IDs in hosts/homelab/nixbot.nix and its secrets,
# encrypted with age for the recipients secrets/secrets.nix lists, in
# secrets/nixbot/. Secrets travel only through memory and stdin: none is
# printed or passed as an argument. docs/nixbot.md has the procedure.

const API = "https://api.github.com"

# The checkout to write into: the JJ workspace around the current directory,
# which must hold the file that names the App.
def checkout-root [app: string]: nothing -> string {
  let found = ^jj workspace root | complete
  if $found.exit_code != 0 {
    error make --unspanned { msg: "Run nixbot-register inside a JJ workspace of the dotfiles repository." }
  }
  let root = $found.stdout | str trim
  if not ($root | path join $app | path exists) {
    error make --unspanned { msg: $"($root) has no ($app); run nixbot-register from the dotfiles repository." }
  }
  $root
}

# The IDs a file like hosts/homelab/nixbot.nix names, as Nix reads them.
def app-ids [file: path]: nothing -> record {
  ^nix-instantiate --eval --strict --json $file | from json
}

# Write the App's IDs into the file that names it, then read them back.
def write-ids [file: path, ids: record<appId: int, oauthId: string>] {
  if $ids.oauthId !~ '^[A-Za-z0-9._-]+$' {
    error make --unspanned { msg: "GitHub returned a client ID nixbot-register does not recognise." }
  }
  open --raw $file
  | str replace --regex '(?m)^(\s*appId = ).*;$' $"${1}($ids.appId);"
  | str replace --regex '(?m)^(\s*oauthId = ).*;$' $"${1}\"($ids.oauthId)\";"
  | save --force $file
  if (app-ids $file) != $ids {
    error make --unspanned { msg: $"Writing the App's IDs into ($file) failed; set appId = ($ids.appId) and oauthId = \"($ids.oauthId)\" there by hand." }
  }
}

# Encrypt each secret of the conversion for its recipients beside its target,
# so a failure leaves no target half written; returns the files to move.
def encrypt [root: path, secrets: list, created: record]: nothing -> list {
  $secrets | each {|secret|
    let target = $root | path join $secret.file
    mkdir ($target | path dirname)
    let staged = $"($target).new"
    let recipients = $secret.recipients | each {|key| [--recipient $key] } | flatten
    $created | get $secret.field | ^age --encrypt ...$recipients --output $staged
    { staged: $staged, target: $target }
  }
}

def main [
  --registration: path # nixbot-registration.json, which the package passes
  --listener: path # listen.py, which the package passes
  --port: int = 0 # Local port for GitHub's redirect; 0 picks a free one
  --show-manifest # Print the App manifest and stop
] {
  let registration = open $registration
  if $show_manifest {
    return ($registration.manifest | to json --indent 2)
  }

  let root = checkout-root $registration.app
  let app_file = $root | path join $registration.app
  let current = app-ids $app_file
  if $current.appId != null {
    error make --unspanned {
      msg: $"($registration.app) already names App ($current.appId). To replace it, delete that App on GitHub, set appId and oauthId back to null, and run nixbot-register again."
    }
  }

  print $"Creating the GitHub App ($registration.manifest.name) for ($registration.manifest.url)."
  print "Click \"Create GitHub App\" on the GitHub page that opens."
  let state = random chars --length 32
  let code = { manifest: $registration.manifest, state: $state }
    | to json
    | ^python3 $listener --port $port
    | str trim

  # The code is good for one exchange within an hour; keep it out of any
  # message.
  let response = try {
    http post --full --allow-errors --content-type application/json --headers {
      Accept: "application/vnd.github+json"
      X-GitHub-Api-Version: "2022-11-28"
    } $"($API)/app-manifests/($code)/conversions" {}
  } catch {|err|
    error make --unspanned { msg: ($err.msg | str replace --all $code "CODE") }
  }
  if $response.status != 201 {
    error make --unspanned {
      msg: $"GitHub refused the manifest conversion \(HTTP ($response.status)\): ($response.body.message? | default '')"
    }
  }
  let created = $response.body
  print $"GitHub created App ($created.id) at ($created.html_url)."

  # Without its secrets stored the App is useless: say how to start over.
  let staged = try {
    let staged = encrypt $root $registration.secrets $created
    $staged | each {|file| mv --force $file.staged $file.target } | ignore
    write-ids $app_file { appId: $created.id, oauthId: $created.client_id }
    $staged
  } catch {|err|
    $registration.secrets | each {|secret| rm --force ($root | path join $"($secret.file).new") } | ignore
    error make --unspanned {
      msg: $"($err.msg)\nDelete App ($created.id) at https://github.com/settings/apps/($created.slug)/advanced, reset ($registration.app) and secrets/nixbot/ with `jj restore`, and run nixbot-register again."
    }
  }
  print $"Encrypted ($staged | length) secrets into ($staged.target | each { path relative-to $root } | str join ', ')."
  print $"Wrote appId and oauthId into ($registration.app)."

  # The rest can be done by hand, so a failure only says how.
  try {
    ^gh repo edit $registration.repository --add-topic $registration.topic
    print $"Added the topic ($registration.topic) to ($registration.repository); nixbot enables it on its first start."
  } catch {
    print $"Add the topic yourself: gh repo edit ($registration.repository) --add-topic ($registration.topic)"
  }

  let install = try {
    let repository_id = ^gh api $"repos/($registration.repository)" --jq .id | str trim
    $"($created.html_url)/installations/new/permissions?suggested_target_id=($created.owner.id)&repository_ids[]=($repository_id)"
  } catch {
    $"($created.html_url)/installations/new"
  }
  print $"Click \"Install\" on the install page that opens, for ($registration.repository) only:"
  print $"  ($install)"
  try { ^xdg-open $install } catch { print "Open that address yourself." }

  print ""
  print "Then gate, merge, and deliver the task; homelab turns nixbot on when it deploys main."
  print "A replaced App also needs the main-checks ruleset changed first: see docs/nixbot.md."
}
