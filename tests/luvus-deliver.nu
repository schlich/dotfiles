# luvus-deliver's risk classification and mitigations, on a throwaway
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
    canaries: { homelab: "ssh://homelab:2222" }
    destinations: { asus: asus, homelab: "ssh://homelab:2222", spare: spare }
  } | to json | save $den
  # What main builds for each host, and what each runs, in place of
  # evaluating the flake and asking the hosts: asus runs an older system with
  # main's home, and homelab, the canary, already runs main, which the
  # staged switch rebuilt under a label ending in the evaluated path's hash.
  let closures = ($tmp | path join closures.json)
  {
    asus: { system: "/nix/store/aaa2-nixos-system-asus", homes: { "schlich@asus": "/nix/store/home-2" } }
    homelab: { system: "/nix/store/hhh2-nixos-system-homelab", homes: {} }
  } | to json | save $closures
  let generations = ($tmp | path join generations.json)
  {
    asus: { system: { generation: 5, path: "/nix/store/aaa1-nixos-system-asus", staged: false }, home: { path: "/nix/store/home-2" } }
    homelab: { system: { generation: 9, path: "/nix/store/xyz9-nixos-system-homelab-26.11-hhh2", staged: false }, home: { path: "/nix/store/embedded" } }
  } | to json | save $generations
  let ledger = ($tmp | path join risk.jsonl)
  # What each host's boot loaders keep, in place of evaluating them.
  let loaders = ($tmp | path join loaders.json)
  let set_loaders = {|limit| { asus: [{ loader: limine, enable: true, limit: $limit } { loader: grub, enable: false, limit: 100 }] } | to json | save --force $loaders }
  do $set_loaders null

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
  # An age file's header names each recipient; GPxkSA is the tag of the
  # declared key, so the first file is encrypted as declared.
  let admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJRdPuDm1hX5iOgHNl63aUVPIUvkMhAFlBaoxOiSPEA"
  let age = {|tags: list, body: string|
    ["age-encryption.org/v1" ...($tags | each {|tag| $"-> ssh-ed25519 ($tag) c2hhcmVk\nYm9keQ" }) "-> x-grease abc\nZ3JlYXNl" $"--- bWFj\n($body)"] | str join "\n"
  }
  do $write "secrets/secrets.nix" $"{\n  \"token.age\".publicKeys = [ \"($admin)\" ];\n}\n"
  do $write "secrets/token.age" (do $age [GPxkSA] "v1")
  let ruleset = {|bypass: list|
    {
      name: main-checks, target: branch, enforcement: active
      conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } }
      rules: [
        { type: deletion } { type: non_fast_forward }
        { type: required_status_checks, parameters: { required_status_checks: [{ context: nixbot/nix-eval, integration_id: 7 } { context: nixbot/nix-build, integration_id: 7 }] } }
      ]
      bypass_actors: $bypass
    } | to json
  }
  do $write ".github/rulesets/main-checks.json" (do $ruleset [])
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
      LUVUS_DELIVER_LOADERS: $loaders
      LUVUS_DELIVER_CLOSURES: $closures
      LUVUS_DELIVER_GENERATIONS: ($env.LUVUS_DELIVER_GENERATIONS? | default $generations)
      USER: schlich
      LUVUS_DELIVER_HOST: ($env.LUVUS_DELIVER_HOST? | default "builder")
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

  do $case secret { "secrets/token.age": (do $age [GPxkSA] "v2") } | ignore
  let secret = (do $verdict)
  $failures = ($failures | append (expect "a secret is mitigated by checking its recipients" [$secret.risk ($secret.mitigations | get id)] [high [secret-recipients]]))
  do $case gate { "tools/luvus-deliver.nu": "def main [] { }\n" } | ignore
  let gate = (do $verdict)
  $failures = ($failures | append (expect "a change to the classifier is judged by it too" [$gate.risk ($gate.mitigations | get id)] [high [classifier-stricter]]))
  do $case hardware { "hosts/asus/hardware-configuration.nix": "{ fileSystems.\"/\".device = \"/dev/sda\"; }\n" } | ignore
  let hardware = (do $verdict)
  $failures = ($failures | append (expect "a host's own files are mitigated by its boot menu and the canary" [$hardware.risk ($hardware.mitigations | get id) ($hardware.mitigations | where id == boot-rollback | get 0.hosts)] [high [boot-rollback canary-first] [asus]]))

  # Delivering: a high-risk delivery never waits for approval. Mitigations
  # that judge the commit run before the push, and a failed one stops the
  # delivery with nothing pushed. Past the push, `gh` cannot reach GitHub,
  # so these runs end there.
  let pushed = {||
    let found = (^git -C $origin rev-parse --verify --quiet refs/heads/luvus/integration | complete)
    let sha = ($found.stdout | str trim)
    if $found.exit_code == 0 { ^git -C $origin update-ref -d refs/heads/luvus/integration }
    $sha
  }
  let deliver = {|name: string, edits: record|
    let head = (do $case $name $edits)
    let result = (do $run [--repo $repo])
    { head: $head, result: $result, pushed: (do $pushed) }
  }
  let rekeyed = (do $deliver unrekeyed { "secrets/token.age": (do $age [JgP3tw] "v3") })
  $failures = ($failures | append (expect "a secret not encrypted to its declared keys stops before pushing" [($rekeyed.result.stderr | str contains "secret-recipients failed") ($rekeyed.result.stdout | str contains "rekey it with agenix") $rekeyed.pushed] [true true ""]))
  let undeclared = (do $deliver undeclared { "secrets/other.age": (do $age [GPxkSA] "x") })
  $failures = ($failures | append (expect "an undeclared secret stops before pushing" [($undeclared.result.stdout | str contains "secrets/other.age is not declared") $undeclared.pushed] [true ""]))
  let rekey = (do $deliver rekeyed { "secrets/token.age": (do $age [GPxkSA] "v4") })
  $failures = ($failures | append (expect "a secret encrypted to its declared keys is pushed without approval" $rekey.pushed $rekey.head))

  let bypass = (do $deliver bypass { ".github/rulesets/main-checks.json": (do $ruleset [{ actor_id: 1, actor_type: RepositoryRole }]) })
  $failures = ($failures | append (expect "a ruleset that loses a guarantee stops before pushing" [($bypass.result.stdout | str contains "it has bypass actors") $bypass.pushed] [true ""]))

  do $set_loaders 1
  let short_menu = (do $deliver short-menu { "hosts/asus/hardware-configuration.nix": "{ fileSystems.\"/\".device = \"/dev/sdb\"; }\n" })
  $failures = ($failures | append (expect "a host change that leaves too short a boot menu stops before pushing" [($short_menu.result.stdout | str contains "keeps only 1 generations") $short_menu.pushed] [true ""]))
  do $set_loaders null
  let hardware_ok = (do $deliver hardware-ok { "hosts/asus/hardware-configuration.nix": "{ fileSystems.\"/\".device = \"/dev/sdc\"; }\n" })
  $failures = ($failures | append (expect "a host change with a full boot menu is pushed without approval" $hardware_ok.pushed $hardware_ok.head))

  let broken = (do $deliver broken-classifier { "tools/luvus-deliver.nu": "def main [] { }\n" })
  $failures = ($failures | append (expect "a classifier that cannot judge its own delivery stops before pushing" [($broken.result.stderr | str contains "classifier-stricter failed") $broken.pushed] [true ""]))
  let working = (do $deliver working-classifier { "tools/luvus-deliver.nu": (open --raw $script) })
  $failures = ($failures | append (expect "a classifier that judges its own delivery is pushed without approval" [($working.result.stdout | str contains "✓ classifier-stricter") $working.pushed] [true $working.head]))

  let low = (do $deliver low { "docs/guide.md": "# Guide\n\nLast words.\n" })
  $failures = ($failures | append (expect "a low-risk delivery is pushed" $low.pushed $low.head))
  let entries = (open --raw $ledger | lines | each { from json })
  $failures = ($failures | append (expect "the ledger keeps how each delivery's mitigations ended" ($entries | where head == $rekeyed.head | get 0 | select risk stage) { risk: high, stage: mitigation-failed }))
  $failures = ($failures | append (expect "the ledger names each mitigation's outcome" ($entries | where head == $rekey.head | get 0.outcomes | select id ok) [[id ok]; [secret-recipients true]]))

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
  let delivered = (with-env { PATH: $path } { do $run [--repo $repo] })
  $failures = ($failures | append (expect "a delivery fast-forwards main and the local main tasks start from" [(^git -C $origin rev-parse main | str trim) (^git -C $repo rev-parse main | str trim)] [$shipped $shipped]))

  # Once main moves, the delivery says what each deployed host needs and
  # the command that applies it, which names the host.
  let said = ($delivered.stdout | lines | each { str trim })
  $failures = ($failures | append (expect "a delivery ends with each host's next step" [
    ($said | any {|line| $line =~ '^asus\s+needs its system → system-switch asus --with-home$' })
    ($said | any {|line| $line =~ '^homelab\s+up to date \(generation 9\)$' })
  ] [true true]))
  let steps = {|file: string|
    let result = (with-env { LUVUS_DELIVER_GENERATIONS: $file } { do $run [hosts --repo $repo --json] })
    if $result.exit_code == 0 { $result.stdout | from json | select host state needs command } else { $result.stderr }
  }
  let behind = ($tmp | path join behind.json)
  {
    homelab: { system: { generation: 8, path: "/nix/store/xyz8-nixos-system-homelab-26.11-hhh1", staged: false } }
  } | to json | save $behind
  $failures = ($failures | append (expect "a canary behind main gets no command, and an unreachable host keeps its command" (do $steps $behind) [
    { host: asus, state: unreachable, needs: [], command: "system-switch asus --with-home" }
    { host: homelab, state: behind, needs: [system], command: null }
  ]))
  let home_behind = ($tmp | path join home-behind.json)
  {
    asus: { system: { generation: 6, path: "/nix/store/aaa2-nixos-system-asus", staged: false }, home: { path: "/nix/store/home-1" } }
    homelab: { system: { generation: 9, path: "/nix/store/xyz9-nixos-system-homelab-26.11-hhh2", staged: false } }
  } | to json | save $home_behind
  $failures = ($failures | append (expect "a standalone home behind main needs the same command" (do $steps $home_behind | get 0) { host: asus, state: behind, needs: [home], command: "system-switch asus --with-home" }))

  # canary-first: once main moves, the delivery waits for the canary, which
  # an ssh stub answers from CANARY_REVERTED and CANARY_RAN.
  [
    "#!/bin/sh"
    "for arg; do last=\"$arg\"; case \"$arg\" in deploy-reverts) cmd=reverts ;; generation) cmd=generation ;; esac; done"
    "case \"$cmd\" in"
    "  reverts) if [ -n \"$CANARY_REVERTED\" ]; then printf '[{\"rev\":\"%s\",\"phase\":\"watch\",\"breached\":[\"settle\"],\"report\":\"/r.md\"}]' \"$CANARY_REVERTED\"; else echo '[]'; fi ;;"
    "  generation) printf '{\"system\":{\"generation\":9,\"staged\":false},\"source\":{\"rev\":\"%s\",\"matches_through\":null}}' \"$CANARY_RAN\" ;;"
    "esac"
  ] | str join "\n" | save ($bin | path join ssh)
  ^chmod +x ($bin | path join ssh)
  let canary = {|name: string, file: string, reverted: bool|
    let head = (do $case $name { $file: $"{ shared = \"($name)\"; }\n" })
    let result = (with-env { PATH: $path, CANARY_RAN: $head, CANARY_REVERTED: (if $reverted { $head } else { "" }) } { do $run [--repo $repo --poll "1sec"] })
    { head: $head, result: $result, main: (^git -C $origin rev-parse main | str trim) }
  }
  let deployed = (do $canary canary-ok "hosts/shared.nix" false)
  $failures = ($failures | append (expect "a canary-first delivery finishes once the canary deployed it" [$deployed.result.exit_code ($deployed.result.stdout | str contains "✓ canary-first: homelab deployed") $deployed.main] [0 true $deployed.head]))
  let reverted = (do $canary canary-reverted "hosts/shared.nix" true)
  $failures = ($failures | append (expect "a canary that reverts the delivery fails it after main moved" [($reverted.result.exit_code != 0) ($reverted.result.stderr | str contains "Switch no other host to it") $reverted.main] [true true $reverted.head]))
  let stages = (open --raw $ledger | lines | each { from json } | where head in [$deployed.head $reverted.head] | where stage in [delivered canary-failed] | get stage)
  $failures = ($failures | append (expect "the ledger records how the canary ended" $stages [delivered canary-failed]))

  # Run on the canary itself, the delivery asks it directly: its own
  # generation and deploy-reverts, which the stub's ssh would refuse.
  for name in [deploy-reverts generation] {
    ["#!/bin/sh" $"exec ($bin)/ssh canary ($name) \"$@\""] | str join "\n" | save ($bin | path join $name)
    ^chmod +x ($bin | path join $name)
  }
  ["#!/bin/sh" "[ \"$1\" = canary ] || exit 255"] | append (open --raw ($bin | path join ssh) | lines | skip 1) | str join "\n" | save --force ($bin | path join ssh)
  let local = (with-env { LUVUS_DELIVER_HOST: homelab } { do $canary canary-local "hosts/shared.nix" false })
  $failures = ($failures | append (expect "a delivery run on the canary asks it directly" [$local.result.exit_code ($local.result.stdout | str contains "✓ canary-first: homelab deployed")] [0 true]))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) luvus-deliver checks failed: ($failures | str join ', ')" }
  }
  print "All luvus-deliver checks passed."
}
