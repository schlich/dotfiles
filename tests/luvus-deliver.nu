# luvus-deliver's risk classification and approval, on a throwaway
# repository with a bare origin and a fixture of what tools/den-reach.nix
# returns, so nothing reaches GitHub:
#   nu --no-config-file tests/luvus-deliver.nu tools/luvus-deliver.nu

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def main [script: path] {
  let script = ($script | path expand)
  let tmp = (mktemp --directory)
  $env.GIT_AUTHOR_NAME = "check"
  $env.GIT_AUTHOR_EMAIL = "check@localhost"
  $env.GIT_COMMITTER_NAME = "check"
  $env.GIT_COMMITTER_EMAIL = "check@localhost"
  mut failures = []

  # What den-reach.nix would say of a fleet of a workstation and a server
  # that share the shell home.
  let den = ($tmp | path join den.json)
  {
    systems: { asus: [base workstation], homelab: [base homelab-platform], spare: [base workstation] }
    homes: { "schlich@asus": [user-shell], "schlich@homelab": [user-shell] }
    deployed: [asus homelab]
    risks: { base: medium, workstation: medium, homelab-platform: high, user-shell: null }
  } | to json | save $den
  let ledger = ($tmp | path join risk.jsonl)

  let origin = ($tmp | path join origin.git)
  let repo = ($tmp | path join repo)
  ^git init --quiet --bare $origin
  ^git init --quiet -b main $repo
  let write = {|path: string, text: string|
    let file = ($repo | path join $path)
    mkdir ($file | path dirname)
    $text | save --force $file
  }
  let commit = {|message: string|
    ^git -C $repo add --all
    ^git -C $repo commit --quiet -m $message
    ^git -C $repo rev-parse HEAD | str trim
  }
  do $write "den/aspects/platforms.nix" "{ ... }:\n{\n  den.aspects.homelab-platform = {\n    nixos.imports = [ ../../modules/nixos/service.nix ];\n  };\n  den.aspects.workstation = {\n    nixos.imports = [ ../../modules/nixos/desktop.nix ];\n  };\n}\n"
  do $write "den/aspects/users/shell.nix" "{ ... }:\n{\n  den.aspects.user-shell.homeManager.imports = [ ../../../modules/programs/shell.nix ];\n}\n"
  do $write "modules/nixos/service.nix" "{ imports = [ ./service-helper.nix ]; }\n"
  do $write "modules/nixos/service-helper.nix" "{ services.example.enable = true; }\n"
  do $write "modules/nixos/desktop.nix" "{ programs.niri.enable = true; }\n"
  do $write "modules/programs/shell.nix" "{ imports = [ ./tool.nix ]; programs.nushell.enable = true; }\n"
  do $write "modules/programs/tool.nix" "{ inputs, ... }: { home.packages = [ inputs.tool.packages.default ]; }\n"
  do $write "docs/guide.md" "# Guide\n"
  do $write "secrets/token.age" "age-encrypted-v1\n"
  let lock = {|rev: string|
    { nodes: { root: { inputs: { nixpkgs: nixpkgs, tool: tool } }, nixpkgs: { locked: { rev: a } }, tool: { locked: { rev: $rev } } }, root: root, version: 7 } | to json
  }
  do $write "flake.lock" (do $lock "b")
  let main_sha = (do $commit "base")
  ^git -C $repo remote add origin $origin
  ^git -C $repo push --quiet origin main

  # Each case is one commit on main, delivered as luvus/integration.
  let case = {|name: string, edits: record|
    ^git -C $repo checkout --quiet -B $"case-($name)" main
    for edit in ($edits | transpose path text) {
      do $write $edit.path $edit.text
    }
    let head = (do $commit $name)
    ^git -C $repo branch --quiet --force luvus/integration $head
    $head
  }
  let run = {|args: list|
    with-env {
      HOME: $tmp
      LUVUS_DELIVER_DEN: $den
      LUVUS_DELIVER_LEDGER: $ledger
    } { ^$nu.current-exe --no-config-file $script ...$args | complete }
  }
  let verdict = {||
    let result = (do $run [risk --repo $repo --json])
    if $result.exit_code == 0 { $result.stdout | from json } else { { risk: error, error: $result.stderr } }
  }

  do $case docs { "docs/guide.md": "# Guide\n\nMore words.\n" } | ignore
  let docs = (do $verdict)
  $failures = ($failures | append (expect "documentation alone is low risk" [$docs.risk $docs.hosts $docs.reasons] [low [] []]))

  do $case service { "modules/nixos/service-helper.nix": "{ services.example.enable = false; }\n" } | ignore
  let service = (do $verdict)
  $failures = ($failures | append (expect "a module reaches its host through the module that imports it" [$service.risk $service.hosts ($service.files | where path == "modules/nixos/service-helper.nix" | get 0.systems)] [medium [homelab] [homelab]]))
  $failures = ($failures | append (expect "a file carries the policy risk of what it reaches" ($service.files | get 0.policy_risk) high))

  do $case comment { "modules/nixos/service-helper.nix": "{\n  # Example.\n  services.example.enable = true;\n}\n" } | ignore
  let comment = (do $verdict)
  $failures = ($failures | append (expect "a comment and layout edit reaches no host" [$comment.risk ($comment.files | get 0.layout_only)] [low true]))

  do $case shell { "modules/programs/shell.nix": "{ imports = [ ./tool.nix ]; programs.nushell.enable = false; }\n" } | ignore
  let shell = (do $verdict)
  $failures = ($failures | append (expect "a small change to several hosts needs no approval" [$shell.risk $shell.hosts] [medium [asus homelab]]))

  do $case server { "modules/nixos/service.nix": "{ imports = [ ./service-helper.nix ]; services.other.enable = true; }\n" } | ignore
  let server = (do $verdict)
  $failures = ($failures | append (expect "high-risk configuration on one host needs no approval" [$server.risk ($server.reasons | is-empty)] [medium true]))

  do $case lock { "flake.lock": (do $lock "c") } | ignore
  let locked = (do $verdict)
  $failures = ($failures | append (expect "a flake.lock update reaches the hosts that use the input" [$locked.risk $locked.inputs $locked.hosts] [medium [tool] [asus homelab]]))

  # Inputs grouped in flakes under lib/inputs keep the names modules use:
  # moving one into a group updates nothing, and updating it there names it.
  let grouped = {
    nodes: {
      root: { inputs: { system: inputs-system, terminal: inputs-terminal } }
      inputs-system: { inputs: { nixpkgs: nixpkgs }, locked: { path: "./lib/inputs/system", type: path }, parent: [] }
      inputs-terminal: { inputs: { shell: inputs-terminal-shell }, locked: { path: "./lib/inputs/terminal", type: path }, parent: [] }
      inputs-terminal-shell: { inputs: { tool: tool }, locked: { path: "./shell", type: path }, parent: [terminal] }
      nixpkgs: { locked: { rev: a } }
      tool: { inputs: { nixpkgs: [system nixpkgs] }, locked: { rev: d } }
    }
    root: root
    version: 7
  } | to json
  do $case grouped-lock { "flake.lock": $grouped } | ignore
  let regrouped = (do $verdict)
  $failures = ($failures | append (expect "an input updated inside a group is named as modules name it" [$regrouped.inputs $regrouped.hosts] [[tool] [asus homelab]]))

  do $case secret { "secrets/token.age": "age-encrypted-v2\n" } | ignore
  let secret = (do $verdict)
  $failures = ($failures | append (expect "a secret always needs approval" [$secret.risk ($secret.reasons | any { str contains "secrets/token.age always needs approval" })] [high true]))
  do $case gate { "tools/luvus-deliver.nu": "def main [] { }\n" } | ignore
  let gate = (do $verdict)
  $failures = ($failures | append (expect "a change to the classifier always needs approval" [$gate.risk ($gate.reasons | any { str contains "tools/luvus-deliver.nu always needs approval" })] [high true]))

  # Delivering: a high-risk delivery stops before it pushes unless the owner
  # approved that exact commit. Past the push, `gh` cannot reach GitHub, so
  # these runs end there.
  let pushed = {||
    let found = (^git -C $origin rev-parse --verify --quiet refs/heads/luvus/integration | complete)
    let sha = ($found.stdout | str trim)
    if $found.exit_code == 0 { ^git -C $origin update-ref -d refs/heads/luvus/integration }
    $sha
  }
  let risky = (do $case risky { "hosts/asus/hardware-configuration.nix": "{ fileSystems.\"/\".device = \"/dev/sda\"; }\n" })
  let refused = (do $run [--repo $repo])
  $failures = ($failures | append (expect "a high-risk delivery stops before pushing" [($refused.exit_code != 0) ($refused.stderr | str contains "needs the owner's approval") (do $pushed)] [true true ""]))
  let wrong = (do $run [--repo $repo --approve ($main_sha | str substring 0..11)])
  $failures = ($failures | append (expect "an approval of another commit is refused" [($wrong.stderr | str contains "approval covers one exact commit") (do $pushed)] [true ""]))
  let by_branch = (do $run [--repo $repo --approve luvus/integration])
  $failures = ($failures | append (expect "an approval must name a commit, not a branch" [($by_branch.stderr | str contains "approval covers one exact commit") (do $pushed)] [true ""]))
  do $run [--repo $repo --approve ($risky | str substring 0..11)] | ignore
  $failures = ($failures | append (expect "an approved high-risk delivery is pushed" (do $pushed) $risky))
  let low = (do $case low { "docs/guide.md": "# Guide\n\nLast words.\n" })
  do $run [--repo $repo] | ignore
  $failures = ($failures | append (expect "a low-risk delivery is pushed without approval" (do $pushed) $low))
  let entries = (open --raw $ledger | lines | each { from json })
  $failures = ($failures | append (expect "the ledger keeps each delivery's verdict and approval" ($entries | select risk approved) [[risk approved]; [high false] [high true] [low false]]))

  # Past nixbot's checks, which a gh stub reports as passed, a delivery moves
  # main on the remote and the local main that luvus starts board tasks from.
  let bin = ($tmp | path join bin)
  mkdir $bin
  [
    "#!/bin/sh"
    "case \"$1\" in"
    "  repo) echo owner/repo ;;"
    "  api) echo '{\"check_runs\":[{\"name\":\"nixbot\",\"status\":\"completed\",\"conclusion\":\"success\",\"completed_at\":\"2026-01-01T00:00:00Z\"}]}' ;;"
    "esac"
  ] | str join "\n" | save ($bin | path join gh)
  ^chmod +x ($bin | path join gh)
  let shipped = (do $case shipped { "docs/guide.md": "# Guide\n\nShipped.\n" })
  let path = ($env.PATH | each {|p| $p | split row (char esep) } | flatten | prepend $bin)
  with-env { PATH: $path } { do $run [--repo $repo] } | ignore
  $failures = ($failures | append (expect "a delivery fast-forwards main and the local main tasks start from" [(^git -C $origin rev-parse main | str trim) (^git -C $repo rev-parse main | str trim)] [$shipped $shipped]))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) luvus-deliver checks failed: ($failures | str join ', ')" }
  }
  print "All luvus-deliver checks passed."
}
