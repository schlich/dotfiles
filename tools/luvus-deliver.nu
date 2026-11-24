# Deliver luvus's integration branch to main. First it works out how risky
# the delivery is from which hosts each changed file reaches and which paths
# it changes. A high-risk delivery never waits for a person: its verdict
# names the mitigations that must pass instead, and a failed mitigation fails
# the delivery like a failed check. Those that judge the commit run before
# anything is pushed; canary-first runs once main has moved, so the
# delivering agent switches no other host until the canary has deployed the
# commit. Then it pushes the branch to GitHub, waits for nixbot's checks on
# that commit, and moves main to it. The main-checks ruleset admits only a
# commit whose nixbot checks passed, and GitHub refuses a push that is not a
# fast-forward, so this never rewrites main. It waits for homelab to build,
# so agents run it as a `job-log` job.

# vcs.nix replaces this with a store path. Tests replace it with
# LUVUS_DELIVER_DEN, a JSON file of what den-reach.nix returns.
const default_reach = "@reach@"

# Changed paths that carry a mitigation whatever hosts they reach: secrets
# and the keys they are encrypted to, host-local hardware, storage, and boot
# files, what gates main, and this classifier with the Den reach it reads.
# A change under hosts/NAME/ also checks that NAME's boot menu keeps earlier
# generations (boot-rollback).
const guarded_paths = [
  { pattern: '^secrets/', mitigation: secret-recipients }
  { pattern: '^hosts/login-keys\.nix$', mitigation: secret-recipients }
  { pattern: '^hosts/', mitigation: canary-first }
  { pattern: '^\.github/rulesets/', mitigation: ruleset-guarantees }
  { pattern: '^tools/luvus-deliver\.nu$', mitigation: classifier-stricter }
  { pattern: '^tools/den-reach\.nix$', mitigation: classifier-stricter }
]

# The mitigations this classifier knows, in the order they run.
const known_mitigations = [classifier-stricter secret-recipients ruleset-guarantees boot-rollback canary-first]

# A boot menu shorter than this leaves too little to roll back to.
const min_boot_generations = 3

# The files a delivery changes, with their line counts; a binary file has
# none.
def changed-files [root: string, base: string, head: string] {
  let counts = (^git -C $root diff --numstat --no-renames $base $head | lines | parse "{added}\t{removed}\t{path}")
  let count = {|value| if $value == null or $value == "-" { null } else { $value | into int } }
  ^git -C $root diff --name-status --no-renames $base $head | lines | parse "{status}\t{path}" | each {|row|
    let counted = ($counts | where path == $row.path | get -o 0)
    {
      path: $row.path
      status: (match $row.status { "A" => "added", "D" => "deleted", "M" => "modified", _ => "changed" })
      added: (do $count $counted.added?)
      removed: (do $count $counted.removed?)
    }
  }
}

# A path that a Nix file names relative to itself, from the repository's
# root: "" for the root itself, null outside the repository.
def resolve [file: string, ref: string] {
  let joined = ("/r" | path join ($file | path dirname) $ref | path expand --no-symlink)
  if $joined == "/r" { "" } else if ($joined | str starts-with "/r/") { $joined | str substring 3.. } else { null }
}

# Every repository path a Nix file names at `rev`: the modules each aspect
# and module imports, and the files they read. A reference to the root
# itself, as checks and secret paths make, reads nothing in particular.
def references [root: string, rev: string] {
  ^git -C $root grep -n -I -o -E '\.{1,2}/[A-Za-z0-9_./-]*' $rev -- '*.nix'
  | lines
  | parse --regex '^[^:]+:(?<file>[^:]+):(?<line>\d+):(?<ref>.*)$'
  | each {|row| { file: $row.file, line: ($row.line | into int), target: (resolve $row.file $row.ref) } }
  | where {|row| $row.target != null and $row.target != "" }
}

# Where each Den aspect is defined at `rev`: the lines that assign
# `den.aspects.NAME`, not those that only include it.
def aspect-definitions [root: string, rev: string] {
  ^git -C $root grep -n -E '^\s*den\.aspects\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_.-]+)?\s*=' $rev -- 'den/aspects'
  | lines
  | parse --regex '^[^:]+:(?<file>[^:]+):(?<line>\d+):\s*den\.aspects\.(?<name>[A-Za-z0-9_-]+)'
  | update line { into int }
}

# The aspects a line of an aspect file belongs to: the definition above it,
# or every aspect the file defines when none is.
def aspects-at [file: string, line: int, definitions: list] {
  let own = ($definitions | where {|row| $row.file == $file })
  let above = ($own | where {|row| $row.line <= $line })
  if ($above | is-empty) { $own | get name } else { [($above | sort-by line | last | get name)] }
}

# What reads `path`, directly or through the files that import it: the Den
# aspects, whether Den's host composition does, and whether only the
# flake's own outputs, such as its checks, do.
def reach [path: string, refs: list, definitions: list] {
  if ($path | str starts-with "den/aspects/") {
    return { aspects: ($definitions | where {|row| $row.file == $path } | get name | uniq), composition: false, flake: false }
  }
  if ($path | str starts-with "den/") {
    return { aspects: [], composition: true, flake: false }
  }
  mut frontier = [$path]
  mut seen = [$path]
  mut aspects = []
  mut composition = false
  mut flake = ($path == "flake.nix")
  while ($frontier | is-not-empty) {
    let current = ($frontier | first)
    $frontier = ($frontier | skip 1)
    let readers = ($refs | where {|ref|
      $ref.file != $current and ($ref.target == $current or ($current | str starts-with $"($ref.target)/"))
    })
    for ref in $readers {
      if ($ref.file | str starts-with "den/aspects/") {
        $aspects = ($aspects | append (aspects-at $ref.file $ref.line $definitions))
      } else if ($ref.file | str starts-with "den/") {
        $composition = true
      } else if $ref.file == "flake.nix" {
        $flake = true
      } else if $ref.file not-in $seen {
        $seen = ($seen | append $ref.file)
        $frontier = ($frontier | append $ref.file)
      }
    }
  }
  { aspects: ($aspects | uniq | sort), composition: $composition, flake: $flake }
}

# Whether a Nix file changed only in its comments and layout: both versions
# parse to the same expression. One that cannot be parsed counts as changed.
def layout-only [root: string, base: string, head: string, path: string] {
  if not ($path | str ends-with ".nix") { return false }
  let parse = {|rev|
    let source = (^git -C $root show $"($rev):($path)" | complete)
    let parsed = if $source.exit_code == 0 {
      ^nix-instantiate --parse --store dummy:// -E $source.stdout | complete
    } else { { exit_code: 1 } }
    if $parsed.exit_code == 0 { $parsed.stdout } else { null }
  }
  let before = (do $parse $base)
  $before != null and $before == (do $parse $head)
}

def lock-at [root: string, rev: string] {
  let shown = (^git -C $root show $"($rev):flake.lock" | complete)
  if $shown.exit_code == 0 { $shown.stdout | from json } else { { nodes: {} } }
}

# What a lock's node `node` pins: its own locked source and those of
# everything it depends on, by content, so that a lock whose nodes were only
# renumbered pins the same.
def pinned [nodes: record, node: string] {
  mut pending = [$node]
  mut seen = []
  while ($pending | is-not-empty) {
    let next = ($pending | first)
    $pending = ($pending | skip 1)
    if $next not-in $seen {
      $seen = ($seen | append $next)
      # A list is a `follows` path, which names an input another node owns.
      $pending = ($pending | append ($nodes | get -o $next | get -o inputs | default {} | values | where {|v| ($v | describe) == "string" }))
    }
  }
  $seen | each {|name| $nodes | get -o $name | get -o locked | to json --raw } | uniq | sort
}

# A lock's inputs by the names modules use: the root's own, and those of the
# group flakes under lib/inputs, which are relative path inputs. A value that
# is not a string is a `follows` path.
def leaf-inputs [nodes: record, node: string = "root"] {
  $nodes | get -o $node | get -o inputs | default {} | transpose name node | reduce --fold {} {|row, all|
    let target = if ($row.node | describe) == "string" { $nodes | get -o $row.node } else { null }
    if $target != null and ($target | get -o locked.type) == "path" and ($target | get -o parent) != null {
      $all | merge (leaf-inputs $nodes $row.node)
    } else {
      $all | insert $row.name $row.node
    }
  }
}

# The flake inputs a delivery updates, by the names modules use: those it
# adds, and those whose locked source, or that of anything they depend on,
# changed.
def updated-inputs [root: string, base: string, head: string] {
  let before = (lock-at $root $base).nodes
  let after = (lock-at $root $head).nodes
  let old_roots = (leaf-inputs $before)
  leaf-inputs $after | transpose name node | where {|row|
    let old = ($old_roots | get -o $row.name)
    ($row.node | describe) == "string" and (
      ($old | describe) != "string" or (pinned $after $row.node) != (pinned $before $old)
    )
  } | get name
}

# The files at `rev` that use flake input `name`.
def input-readers [root: string, rev: string, name: string] {
  let found = (^git -C $root grep -l -E $"inputs\\.\"?($name)\"?\([^A-Za-z0-9_-]|$\)" $rev -- '*.nix' | complete)
  $found.stdout | lines | each { str replace --regex '^[^:]+:' '' }
}

# What reads the inputs a flake.lock change updates, from the files that
# use them.
def lock-reach [readers: list, refs: list, definitions: list] {
  let found = ($readers | each {|file| reach $file $refs $definitions })
  {
    aspects: ($found | get aspects | flatten | uniq | sort)
    composition: ($found | any {|f| $f.composition })
    flake: ($found | any {|f| $f.flake })
  }
}

# Which Den aspects each host's system and each home includes, from
# den-reach.nix evaluated at `rev`.
def den-reach [root: string, rev: string] {
  if ($env.LUVUS_DELIVER_DEN? | is-not-empty) {
    return (open $env.LUVUS_DELIVER_DEN)
  }
  let reach_file = ($env.LUVUS_DELIVER_REACH? | default $default_reach)
  let result = (^nix eval --json $"git+file://($root)?rev=($rev)#den" --apply (open --raw $reach_file) | complete)
  if $result.exit_code != 0 {
    let detail = ($result.stderr | lines | where {|line| $line =~ 'error' } | get -o 0 | default ($result.stderr | str trim))
    error make { msg: $"evaluating Den at ($rev | str substring 0..11) failed: ($detail)" }
  }
  $result.stdout | from json
}

# The hosts whose system, and the homes, that include any aspect `found`
# names; Den's host composition reaches all of them.
def hosts-of [found: record, den: record] {
  let including = {|table| $table | transpose name aspects | where {|row|
    $found.composition or ($row.aspects | any {|aspect| $aspect in $found.aspects })
  } | get name }
  { systems: (do $including $den.systems), homes: (do $including $den.homes) }
}

const risk_levels = [low medium high critical]

# The highest risk den/model/policy.nix assigns an aspect a file reaches, or null;
# Den's host composition reaches every aspect.
def policy-risk [found: record, risks: record] {
  let named = if $found.composition { $risks | values } else { $found.aspects | each {|aspect| $risks | get -o $aspect } }
  let ranks = ($named | where {|risk| $risk in $risk_levels } | each {|risk| $risk_levels | enumerate | where item == $risk | get 0.index })
  if ($ranks | is-empty) { null } else { $risk_levels | get ($ranks | math max) }
}

# One entry per mitigation, with every reason that asked for it and the
# hosts it concerns.
def gather [found: list] {
  $known_mitigations | each {|id|
    let asked = ($found | where id == $id)
    if ($asked | is-empty) { null } else {
      { id: $id, why: ($asked | get why | uniq), hosts: ($asked | get hosts | flatten | uniq | sort) }
    }
  } | compact
}

# How risky delivering `head` onto `base` is, why, and what mitigates it. A
# delivery is high risk when it changes a guarded path, when it reaches
# several deployed hosts through configuration den/model/policy.nix rates
# high or critical, and when which hosts it reaches cannot be worked out;
# each of those names the mitigations that must pass. It is low when no
# host runs anything it changes, and medium otherwise.
def classify [root: string, base: string, head: string] {
  let files = (changed-files $root $base $head)
  let refs = (references $root $head)
  let definitions = (aspect-definitions $root $head)
  let inputs = if ($files | any {|file| $file.path == "flake.lock" }) { updated-inputs $root $base $head } else { [] }
  let den = (try { { reach: (den-reach $root $head) } } catch {|err| { error: $err.msg } })
  let files = ($files | each {|file|
    let layout_only = ($file.status == "modified" and (layout-only $root $base $head $file.path))
    let found = if $file.status == "deleted" or $layout_only {
      # A deleted file's importers changed as well and reach the same hosts;
      # a comment or layout edit changes what no host runs.
      { aspects: [], composition: false, flake: false }
    } else if $file.path == "flake.lock" {
      let readers = ($inputs | each {|name| input-readers $root $head $name } | flatten | uniq)
      lock-reach $readers $refs $definitions
    } else {
      reach $file.path $refs $definitions
    }
    let hosts = if $den.reach? != null { hosts-of $found $den.reach } else { { systems: [], homes: [] } }
    let policy = if $den.reach? != null { policy-risk $found ($den.reach.risks? | default {}) } else { null }
    $file | merge { layout_only: $layout_only, aspects: $found.aspects, policy_risk: $policy } | merge $hosts
  })
  let deployed = ($den.reach?.deployed? | default [])
  let hosts = ($files | each {|file| $file.systems ++ ($file.homes | each { split row "@" | last }) } | flatten | uniq | where {|host| $host in $deployed } | sort)

  let known_hosts = if $den.reach? != null { $den.reach.systems | columns } else { [] }

  let found = (
    []
    # Den could not say what it reaches, so it may reach every host: the
    # canary deploys it before any other host does.
    | append (if $den.error? != null { [{ id: canary-first, why: $"which hosts it reaches is unknown: ($den.error)", hosts: [] }] } else { [] })
    # Several hosts count through configuration den/model/policy.nix rates
    # high or critical, such as deployment or servers.
    | append ($files | where {|file|
      $file.policy_risk in [high critical] and (($file.systems ++ ($file.homes | each { split row "@" | last })) | uniq | where {|host| $host in $deployed } | length) >= 2
    } | each {|file| { id: canary-first, why: $"($file.path) reaches several hosts through ($file.policy_risk)-risk configuration", hosts: [] } })
    | append ($files | each {|file|
      $guarded_paths | where {|guard| $file.path =~ $guard.pattern } | each {|guard| { id: $guard.mitigation, why: $"($file.path) is guarded", hosts: [] } }
    } | flatten)
    | append ($files | each {|file|
      let host = ($file.path | parse --regex '^hosts/(?<host>[^/]+)/' | get -o 0.host)
      if $host != null and $host in $known_hosts { [{ id: boot-rollback, why: $"($file.path) is ($host)'s own configuration", hosts: [$host] }] } else { [] }
    } | flatten)
  )
  let mitigations = (gather $found)
  let reaches_hosts = ($files | any {|file| ($file.systems | is-not-empty) or ($file.homes | is-not-empty) })
  {
    base: $base
    head: $head
    risk: (if ($mitigations | is-not-empty) { "high" } else if not $reaches_hosts { "low" } else { "medium" })
    reasons: ($mitigations | get -o why | default [] | flatten | uniq)
    mitigations: $mitigations
    hosts: $hosts
    inputs: $inputs
    canaries: ($den.reach?.canaries? | default {})
    deployed: $deployed
    destinations: ($den.reach?.destinations? | default {})
    files: ($files | select path status layout_only systems homes aspects policy_risk)
  }
}

def summary [verdict: record] {
  let short = ($verdict.head | str substring 0..11)
  let reach = if ($verdict.hosts | is-empty) { "no deployed host" } else { $verdict.hosts | str join ", " }
  let why = ($verdict.reasons | each {|reason| $"\n  - ($reason)" } | str join "")
  let plan = if ($verdict.mitigations | is-empty) { "" } else {
    $"\nMitigations: ($verdict.mitigations | get id | str join ', ')"
  }
  $"Risk of delivering ($short): ($verdict.risk); it reaches ($reach).($why)($plan)"
}

# The files of `paths` at `rev`, in a new temporary directory.
def extract [root: string, rev: string, paths: list<string>] {
  let dir = (mktemp --directory)
  let present = ($paths | where {|path| (^git -C $root cat-file -e $"($rev):($path)" | complete).exit_code == 0 })
  if ($present | is-not-empty) {
    ^git -C $root archive --format=tar $rev ...$present | ^tar -x -C $dir
  }
  $dir
}

# The recipient stanzas of an age file's header: `-> TYPE ARGS...` lines
# before the `---` MAC line. An armored file is read as its decoded body.
def age-stanzas [file: path] {
  let raw = (open --raw $file | into binary)
  let end = ($raw | bytes index-of 0x[0a 2d 2d 2d 20])
  if $end < 0 { return null }
  $raw | bytes at 0..<$end | decode utf-8 | lines | where {|line| $line starts-with "-> " } | each {|line| $line | str substring 3.. | split row " " }
}

# The tag age writes in an ssh-ed25519 or ssh-rsa stanza: the first four
# bytes of the SHA-256 of the key's wire encoding, in unpadded base64.
def ssh-tag [key: string] {
  $key | split row " " | get 1 | decode base64 | hash sha256 --binary | bytes at 0..3 | encode base64 | str trim --right --char "="
}

# secret-recipients: every age file under secrets/ at `head` is declared in
# secrets/secrets.nix and encrypted to exactly the keys it declares, read
# from each file's header without decrypting it. A forgotten rekey, a key
# dropped from a file, or a file nobody declared fails it.
def check-secrets [root: string, head: string] {
  let dir = (extract $root $head [secrets hosts])
  let declared = (^nix-instantiate --eval --strict --json --store dummy:// ($dir | path join secrets secrets.nix) | complete)
  let problems = if $declared.exit_code != 0 {
    [$"secrets/secrets.nix does not evaluate: ($declared.stderr | lines | where {|line| $line =~ 'error' } | get -o 0 | default ($declared.stderr | str trim))"]
  } else {
    let declared = ($declared.stdout | from json)
    ^git -C $root ls-tree -r --name-only $head secrets | lines | where {|path| $path ends-with ".age" } | each {|path|
      let name = ($path | str substring 8..)
      let keys = ($declared | get -o $name | get -o publicKeys)
      let stanzas = (age-stanzas ($dir | path join $path))
      if $keys == null {
        [$"($path) is not declared in secrets/secrets.nix"]
      } else if $stanzas == null {
        [$"($path) has no age header"]
      } else {
        let want = ($keys | each {|key| if ($key | str starts-with "age1") { "X25519" } else { $"($key | split row ' ' | first) (ssh-tag $key)" } } | sort)
        # age adds a grease stanza of a made-up type to every header.
        let have = ($stanzas | where {|s| ($s | first) in [X25519 ssh-ed25519 ssh-rsa] } | each {|s| if ($s | first) == "X25519" { "X25519" } else { $"($s | first) ($s | get 1)" } } | sort)
        if $want == $have { [] } else { [$"($path) is encrypted to ($have | str join ', '), but secrets.nix declares ($want | str join ', '); rekey it with agenix"] }
      }
    } | flatten
  }
  rm --recursive --force $dir
  $problems
}

# ruleset-guarantees: the main-checks ruleset at `head` still guards main as
# it did at `base`: active on the default branch, no bypass actors, no
# deleting or rewriting main, and both nixbot checks required from the same
# GitHub App.
def check-ruleset [root: string, base: string, head: string] {
  let file = ".github/rulesets/main-checks.json"
  let read = {|rev| let shown = (^git -C $root show $"($rev):($file)" | complete); if $shown.exit_code == 0 { try { $shown.stdout | from json } catch { null } } else { null } }
  let after = (do $read $head)
  if $after == null { return [$"($file) is missing or not JSON"] }
  let before = (do $read $base)
  let required = ($after.rules? | default [] | where type == required_status_checks | get -o 0.parameters.required_status_checks | default [])
  let app = {|rules, context| $rules | where context == $context | get -o 0.integration_id }
  let earlier = ($before.rules? | default [] | where type == required_status_checks | get -o 0.parameters.required_status_checks | default [])
  let types = ($after.rules? | default [] | get type)
  [
    (if $after.enforcement? != "active" { "it is not active" })
    (if "~DEFAULT_BRANCH" not-in ($after.conditions?.ref_name?.include? | default []) { "it no longer covers the default branch" })
    (if ($after.bypass_actors? | default [] | is-not-empty) { "it has bypass actors" })
    (if "deletion" not-in $types { "it no longer blocks deleting main" })
    (if "non_fast_forward" not-in $types { "it no longer blocks rewriting main" })
    ...([nixbot/nix-eval nixbot/nix-build] | each {|context|
      let id = (do $app $required $context)
      let was = (do $app $earlier $context)
      if $id == null { $"it no longer requires ($context)" } else if $was != null and $id != $was { $"($context) is required from App ($id) instead of ($was)" }
    })
  ] | compact | each {|problem| $"($file): ($problem)" }
}

# What each host's boot loaders keep at `rev`: for limine, systemd-boot,
# and grub, whether it is enabled and how many generations its menu keeps
# (null for all). Tests replace the evaluation with LUVUS_DELIVER_LOADERS.
def loaders [root: string, rev: string, host: string] {
  if ($env.LUVUS_DELIVER_LOADERS? | is-not-empty) {
    return (open $env.LUVUS_DELIVER_LOADERS | get $host)
  }
  let apply = 'l: map (n: { loader = n; enable = l.${n}.enable or false; limit = l.${n}.maxGenerations or (l.${n}.configurationLimit or null); }) [ "limine" "systemd-boot" "grub" ]'
  let result = (^nix eval --json $"git+file://($root)?rev=($rev)#nixosConfigurations.($host).config.boot.loader" --apply $apply | complete)
  if $result.exit_code != 0 {
    error make { msg: ($result.stderr | lines | where {|line| $line =~ 'error' } | get -o 0 | default ($result.stderr | str trim)) }
  }
  $result.stdout | from json
}

# boot-rollback: a change to a host's own hardware, storage, or boot files
# leaves its boot menu with earlier generations to roll back to. The staged
# switch keeps the boot default until the host's watch passes; this makes
# sure a host that then fails to boot can still choose the one before.
def check-boot [root: string, head: string, hosts: list<string>] {
  $hosts | each {|host|
    let found = (try { { loaders: (loaders $root $head $host) } } catch {|err| { error: $err.msg } })
    if $found.error? != null {
      [$"($host)'s boot loader could not be evaluated: ($found.error)"]
    } else {
      let enabled = ($found.loaders | where enable)
      if ($enabled | is-empty) {
        [$"($host) enables none of limine, systemd-boot, or grub, so its boot menu cannot be checked"]
      } else {
        $enabled | where {|l| $l.limit != null and $l.limit < $min_boot_generations } | each {|l| $"($host)'s ($l.loader) keeps only ($l.limit) generations; keep at least ($min_boot_generations) to roll back" }
      }
    }
  } | flatten
}

# classifier-stricter: the classifier `head` brings judges the delivery as
# well, with its own Den reach, and every mitigation either asks for runs.
# So a change cannot relax the classifier that judges it, and one that adds
# a mitigation applies it at once. Its own mitigations must be ones this
# classifier knows how to run.
def check-classifier [root: string, branch: string, head: string] {
  let dir = (extract $root $head [tools/luvus-deliver.nu tools/den-reach.nix])
  let script = ($dir | path join tools luvus-deliver.nu)
  let result = if ($script | path exists) {
    let reach = ($dir | path join tools den-reach.nix)
    let env_reach = if ($reach | path exists) { { LUVUS_DELIVER_REACH: $reach } } else { {} }
    with-env $env_reach { ^$nu.current-exe --no-config-file $script risk --repo $root --branch $branch --json | complete }
  } else { { exit_code: 1, stderr: "it deletes tools/luvus-deliver.nu" } }
  rm --recursive --force $dir
  if $result.exit_code != 0 {
    return { problems: [$"the new classifier could not judge this delivery: ($result.stderr | lines | where {|line| $line =~ '(?i)error|msg' } | get -o 0 | default ($result.stderr | str trim))"], mitigations: [] }
  }
  let theirs = (try { $result.stdout | from json | get -o mitigations | default [] } catch { null })
  if $theirs == null { return { problems: ["the new classifier's verdict is not JSON"], mitigations: [] } }
  let unknown = ($theirs | get -o id | default [] | where {|id| $id not-in $known_mitigations })
  {
    problems: ($unknown | each {|id| $"the new classifier asks for ($id), which the installed one cannot run yet; deliver the classifier first, then the change that needs it" })
    mitigations: ($theirs | where {|m| $m.id in $known_mitigations } | each {|m| { id: $m.id, why: ($m.why | each {|w| $"new classifier: ($w)" }), hosts: ($m.hosts? | default []) } })
  }
}

# Run every mitigation that judges the commit itself, before anything is
# pushed. Returns the verdict with the classifier's plan merged in and each
# mitigation's outcome; a failure stops the delivery.
def mitigate-before [root: string, branch: string, verdict: record] {
  mut plan = $verdict.mitigations
  mut outcomes = []
  if "classifier-stricter" in ($plan | get id) {
    let judged = (check-classifier $root $branch $verdict.head)
    $outcomes = ($outcomes | append { id: classifier-stricter, ok: ($judged.problems | is-empty), problems: $judged.problems })
    $plan = (gather ($plan ++ $judged.mitigations | each {|m| $m.why | each {|why| { id: $m.id, why: $why, hosts: $m.hosts } } } | flatten))
  }
  let ids = ($plan | get -o id | default [])
  if "secret-recipients" in $ids {
    let problems = (check-secrets $root $verdict.head)
    $outcomes = ($outcomes | append { id: secret-recipients, ok: ($problems | is-empty), problems: $problems })
  }
  if "ruleset-guarantees" in $ids {
    let problems = (check-ruleset $root $verdict.base $verdict.head)
    $outcomes = ($outcomes | append { id: ruleset-guarantees, ok: ($problems | is-empty), problems: $problems })
  }
  if "boot-rollback" in $ids {
    let problems = (check-boot $root $verdict.head ($plan | where id == boot-rollback | get 0.hosts))
    $outcomes = ($outcomes | append { id: boot-rollback, ok: ($problems | is-empty), problems: $problems })
  }
  if "canary-first" in $ids and ($verdict.canaries | is-empty) {
    $outcomes = ($outcomes | append { id: canary-first, ok: false, problems: ["no canary host is known to deploy it first"] })
  }
  for outcome in $outcomes {
    print $"(if $outcome.ok { '✓' } else { '✗' }) ($outcome.id)($outcome.problems | each {|p| $"\n    ($p)" } | str join '')"
  }
  $verdict | merge { mitigations: $plan, outcomes: $outcomes }
}

# The canary's view of `sha`: deployed once its recorded running system came
# from that revision, or a later one that produced the same system; failed
# once it reverted or rejected it; otherwise still waiting.
def canary-state [host: string, destination: string, sha: string, since: string] {
  # A delivery run on the canary itself asks it directly, not over ssh.
  let here = ($env.LUVUS_DELIVER_HOST? | default (sys host | get hostname))
  let ssh = if $host == $here {
    {|args: list| ^($args | first) ...($args | skip 1 | each {|arg| $arg | str trim --char "'" }) | complete }
  } else {
    {|args: list| ^timeout --kill-after=5 60 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 $destination ...$args | complete }
  }
  # Quoted, since the remote login shell parses the command line.
  let reverts = (do $ssh [deploy-reverts --json --since $"'($since)'"])
  if $reverts.exit_code != 0 { return { state: unreachable, detail: ($reverts.stderr | str trim | lines | last 1 | get -o 0 | default "") } }
  let reverted = (try { $reverts.stdout | from json | where {|row| $row.rev? == $sha } } catch { [] })
  if ($reverted | is-not-empty) {
    let row = ($reverted | last)
    return { state: failed, detail: $"($row.phase? | default 'watch') breached ($row.breached? | default [] | str join ', '); report ($row.report? | default '')" }
  }
  let report = (do $ssh [generation --json])
  if $report.exit_code != 0 { return { state: unreachable, detail: ($report.stderr | str trim | lines | last 1 | get -o 0 | default "") } }
  let report = (try { $report.stdout | from json } catch { null })
  if $report == null { return { state: waiting, detail: "no report" } }
  let source = ($report.source? | default {})
  let ran = [($source.rev? | default "") ($source.matches_through?.rev? | default "")]
  if $sha in $ran and not ($report.system?.staged? | default false) {
    { state: deployed, detail: $"generation ($report.system?.generation? | default '?')" }
  } else {
    { state: waiting, detail: (if ($report.system?.staged? | default false) { "staging" } else { "not deployed yet" }) }
  }
}

# canary-first: once main has moved, wait until every canary has staged the
# commit through its own health watch and made it the boot default, before
# the delivering agent switches any other host. A canary that reverts it,
# or that cannot be reached until the deadline, fails the delivery, so no
# other host is switched to it.
def wait-canaries [canaries: record, sha: string, since: string, deadline: datetime, poll: duration] {
  let short = ($sha | str substring 0..11)
  $canaries | transpose host destination | each {|canary|
    mut done = false
    mut result = []
    mut last = ""
    while not $done {
      let state = (canary-state $canary.host $canary.destination $sha $since)
      if $state.state == deployed {
        print $"✓ canary-first: ($canary.host) deployed ($short) \(($state.detail)\)."
        $done = true
      } else if $state.state == failed {
        $result = [$"($canary.host) reverted ($short): ($state.detail)"]
        $done = true
      } else if (date now) > $deadline {
        $result = [$"($canary.host) had not deployed ($short) by the deadline: ($state.state), ($state.detail)"]
        $done = true
      } else {
        let line = $"Waiting for canary ($canary.host) to deploy ($short): ($state.state), ($state.detail)."
        if $line != $last { print $line }
        $last = $line
        sleep $poll
      }
    }
    $result
  } | flatten
}

# What each host should run at `rev`, by the store paths of its system and
# of the standalone homes built for it, in one evaluation. Tests replace it
# with LUVUS_DELIVER_CLOSURES, a JSON file of what this returns.
const closures_expr = r#'
let
  outputs = builtins.getFlake "@flake@";
  hosts = builtins.fromJSON ''@hosts@'';
  homes = outputs.homeConfigurations or { };
  homesOf = host: builtins.filter (name: builtins.match ".*@${host}" name != null) (builtins.attrNames homes);
in
builtins.listToAttrs (map (host: {
  name = host;
  value = {
    system = outputs.nixosConfigurations.${host}.config.system.build.toplevel.outPath;
    homes = builtins.listToAttrs (map (name: {
      inherit name;
      value = homes.${name}.activationPackage.outPath;
    }) (homesOf host));
  };
}) hosts)
'#

def wanted-closures [root: string, rev: string, hosts: list<string>] {
  if ($env.LUVUS_DELIVER_CLOSURES? | is-not-empty) {
    return (open $env.LUVUS_DELIVER_CLOSURES)
  }
  let expr = ($closures_expr | str replace '@flake@' $"git+file://($root)?rev=($rev)" | str replace '@hosts@' ($hosts | to json --raw))
  let result = (^nix eval --impure --json --expr $expr | complete)
  if $result.exit_code != 0 {
    let detail = ($result.stderr | lines | where {|line| $line =~ 'error' } | get -o 0 | default ($result.stderr | str trim))
    error make { msg: $"evaluating the hosts at ($rev | str substring 0..11) failed: ($detail)" }
  }
  $result.stdout | from json
}

# What `generation --json` reports on a host: here directly, elsewhere over
# ssh. Tests replace it with LUVUS_DELIVER_GENERATIONS, a JSON file of each
# host's report, where a missing host is unreachable.
def running-on [host: string, destination: string] {
  if ($env.LUVUS_DELIVER_GENERATIONS? | is-not-empty) {
    let report = (open $env.LUVUS_DELIVER_GENERATIONS | get -o $host)
    return (if $report == null { { error: "unreachable (fixture)" } } else { $report })
  }
  let here = ($env.LUVUS_DELIVER_HOST? | default (sys host | get hostname))
  let result = if $host == $here {
    ^generation --json --offline | complete
  } else {
    ^timeout --kill-after=5 60 ssh -o BatchMode=yes -o ConnectTimeout=10 $destination generation --json --offline | complete
  }
  if $result.exit_code != 0 {
    return { error: ($result.stderr | str trim | lines | last 1 | get -o 0 | default $"exit ($result.exit_code)") }
  }
  try { $result.stdout | from json } catch { { error: "generation printed no report" } }
}

# Whether a running system is the one `wanted` evaluates to. The staged
# switch (deploy/switch.nu) builds it again under a label that ends in the
# evaluated path's hash, so its running path differs but names that hash;
# Clan deploys the evaluated path itself.
def same-system [running, wanted: string] {
  if $running == null { return false }
  let hash = ($wanted | path basename | split row "-" | first)
  $running == $wanted or ($running | str ends-with $"-($hash)")
}

# For each deployed host, what it still needs to run `rev`, and the command
# that applies it. A host's system and this user's standalone home are
# compared by store path with what `rev` builds, so a landing that changes
# nothing a host runs leaves it up to date. A canary stages main by itself,
# so it gets no command. `system-switch HOST` works from any host.
def host-steps [root: string, rev: string, reach: record] {
  let hosts = ($reach.deployed? | default [] | sort)
  if ($hosts | is-empty) { return [] }
  let wanted = (wanted-closures $root $rev $hosts)
  let canaries = ($reach.canaries? | default {} | columns)
  $hosts | each {|host|
    let destination = ($reach.destinations? | default {} | get -o $host | default $host)
    let command = $"system-switch ($host) --with-home"
    let report = (running-on $host $destination)
    let want = ($wanted | get -o $host)
    if $report.error? != null {
      { host: $host, state: unreachable, needs: [], command: $command, detail: $report.error }
    } else if $want == null {
      { host: $host, state: unknown, needs: [], command: null, detail: $"($rev | str substring 0..11) builds no system for it" }
    } else {
      let home = ($want.homes? | default {} | get -o $"($env.USER)@($host)")
      let needs = (
        (if not (same-system $report.system?.path? $want.system) { [system] } else { [] })
        ++ (if $home != null and $report.home?.path? != $home { [home] } else { [] })
      )
      let generation = ($report.system?.generation? | default '?')
      if ($needs | is-empty) {
        { host: $host, state: current, needs: [], command: null, detail: $"generation ($generation)" }
      } else if $host in $canaries and $home == null {
        let detail = if ($report.system?.staged? | default false) { "staging it now" } else { "its own timer stages main" }
        { host: $host, state: behind, needs: $needs, command: null, detail: $detail }
      } else {
        { host: $host, state: behind, needs: $needs, command: $command, detail: $"runs generation ($generation)" }
      }
    }
  }
}

def steps-summary [steps: list, rev: string] {
  let width = ($steps | get host | each { str length } | append 0 | math max)
  let lines = ($steps | each {|step|
    let name = ($step.host | fill --width $width)
    match $step.state {
      current => $"  ($name)  up to date \(($step.detail)\)"
      unreachable => $"  ($name)  unreachable: ($step.detail); once it answers: ($step.command)"
      unknown => $"  ($name)  ($step.detail)"
      _ => {
        let what = ($step.needs | str join ' and ')
        if $step.command == null { $"  ($name)  needs its ($what): ($step.detail)" } else { $"  ($name)  needs its ($what) → ($step.command)" }
      }
    }
  })
  [$"What each host needs to run main at ($rev | str substring 0..11):"] ++ $lines | str join "\n"
}

# Print what each host needs after a delivery. Main has already moved, so a
# failure here only says so.
def report-hosts [root: string, rev: string, reach: record] {
  try {
    print (steps-summary (host-steps $root $rev $reach) $rev)
  } catch {|err|
    print $"Could not work out what each host needs: ($err.msg). Run `luvus-deliver hosts` to try again."
  }
}

# Tell the owner after the fact that a high-risk delivery landed and what
# mitigated it. A missing notifier never stops a delivery.
def notify-landed [verdict: record] {
  if $verdict.risk != "high" { return }
  let short = ($verdict.head | str substring 0..11)
  try {
    ^notify-send --app-name luvus-deliver $"High-risk delivery landed: ($short)" $"Mitigated by ($verdict.mitigations | get id | str join ', '). Review it in risk.jsonl." | complete | ignore
  }
}

def ledger [] {
  let state = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
  $env.LUVUS_DELIVER_LEDGER? | default ($state | path join "luvus-deliver" "risk.jsonl")
}

# Keep each delivery's verdict and how its mitigations ended, for review
# after landing. `stage` says how far the delivery got. A ledger that cannot
# be written never stops a delivery.
def record-verdict [verdict: record, stage: string] {
  try {
    let path = (ledger)
    mkdir ($path | path dirname)
    let entry = {
      at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
      base: $verdict.base
      head: $verdict.head
      risk: $verdict.risk
      hosts: $verdict.hosts
      reasons: $verdict.reasons
      mitigations: ($verdict.mitigations | get -o id | default [])
      outcomes: ($verdict.outcomes? | default [])
      stage: $stage
    }
    $"($entry | to json --raw)\n" | save --append $path
  }
}

# luvus starts a board task's worktree from the local main branch, which
# nothing else moves, so tasks began on a main weeks old. Move it to what was
# delivered, as a fast-forward, unless a checkout has it.
def advance-local-main [root: string, sha: string] {
  let checked_out = (^git -C $root worktree list --porcelain | lines | any {|line| $line == "branch refs/heads/main" })
  let local = (^git -C $root rev-parse --verify --quiet refs/heads/main | complete)
  if $checked_out {
    print "Left local main alone: a worktree has it checked out."
  } else if $local.exit_code != 0 {
    ^git -C $root update-ref refs/heads/main $sha
  } else if (^git -C $root merge-base --is-ancestor ($local.stdout | str trim) $sha | complete).exit_code == 0 {
    ^git -C $root update-ref refs/heads/main $sha ($local.stdout | str trim)
  } else {
    print "Left local main alone: it has commits this delivery lacks."
  }
}

# The integration branch's head and main's, with main fetched first.
def endpoints [repo: path, branch: string] {
  let root = (^git -C $repo rev-parse --show-toplevel | str trim)
  let sha = (^git -C $root rev-parse --verify $"($branch)^{commit}" | str trim)
  ^git -C $root fetch --quiet origin main
  { root: $root, sha: $sha, main: (^git -C $root rev-parse origin/main | str trim) }
}

# Judge how risky delivering the branch would be, without delivering it.
def "main risk" [
  --repo: path = "."                     # Any checkout of the repository
  --branch: string = "luvus/integration" # The branch luvus merges finished tasks into
  --json                                 # Print the verdict as JSON
] {
  let at = (endpoints $repo $branch)
  if $at.main == $at.sha {
    print "main is already there; nothing to deliver."
    return
  }
  let verdict = (classify $at.root $at.main $at.sha)
  if $json { $verdict | to json } else { summary $verdict }
}

# Say what each deployed host still needs to run main, and the command that
# applies it, as a delivery does once main has moved.
def "main hosts" [
  --repo: path = "." # Any checkout of the repository
  --json             # Print the steps as JSON
] {
  let root = (^git -C $repo rev-parse --show-toplevel | str trim)
  ^git -C $root fetch --quiet origin main
  let rev = (^git -C $root rev-parse origin/main | str trim)
  let steps = (host-steps $root $rev (den-reach $root $rev))
  if $json { $steps | to json } else { steps-summary $steps $rev }
}

def main [
  --repo: path = "."                     # Any checkout of the repository
  --branch: string = "luvus/integration" # The branch luvus merges finished tasks into
  --check: list<string> = [nixbot/nix-eval nixbot/nix-build] # The required check runs on GitHub
  --timeout: duration = 2hr
  --poll: duration = 30sec
] {
  let at = (endpoints $repo $branch)
  let root = $at.root
  let sha = $at.sha
  let main = $at.main
  let short = ($sha | str substring 0..11)
  if $main == $sha {
    print $"main is already at ($short)."
    return
  }
  if (^git -C $root merge-base --is-ancestor $main $sha | complete).exit_code != 0 {
    error make { msg: $"($branch) does not contain origin/main; merge main into it before delivering." }
  }
  let started = (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
  let verdict = (classify $root $main $sha)
  print (summary $verdict)
  let verdict = (mitigate-before $root $branch $verdict)
  let failed = ($verdict.outcomes | where not ok)
  if ($failed | is-not-empty) {
    record-verdict $verdict mitigation-failed
    error make { msg: $"Not delivering ($short): ($failed | get id | str join ', ') failed. Fix what it names on the task's branch and deliver again." }
  }
  record-verdict $verdict pushing
  print $"Pushing ($branch) at ($short)."
  ^git -C $root push --quiet origin $"($sha):refs/heads/($branch)"
  let slug = (do { cd $root; ^gh repo view --json nameWithOwner --jq .nameWithOwner } | str trim)
  let deadline = ((date now) + $timeout)
  # GitHub counts these conclusions as passing a required check.
  let passing = [success neutral skipped]
  loop {
    let latest = $check | each {|name|
      ^gh api --method GET $"repos/($slug)/commits/($sha)/check-runs" -f $"check_name=($name)"
      | from json
      | get check_runs
      | where status == completed
      | sort-by completed_at
      | last
      | default { name: $name, conclusion: null }
    }
    # A failed eval means nix-build may never report, so stop at the first failure.
    let failed = $latest | where conclusion != null and conclusion not-in $passing
    if ($failed | is-not-empty) {
      let first = $failed | first
      error make { msg: $"`($first.name)` concluded ($first.conclusion) on ($short): ($first.html_url? | default '')" }
    }
    let pending = $latest | where conclusion == null | get name
    if ($pending | is-empty) { break }
    if (date now) > $deadline {
      error make { msg: $"Timed out after ($timeout) waiting for ($pending | str join ', ') on ($short)." }
    }
    print $"Waiting for ($pending | str join ', ') on ($short)."
    sleep $poll
  }
  ^git -C $root push --quiet origin $"($sha):refs/heads/main"
  advance-local-main $root $sha
  print $"Delivered: main is now ($short)."
  if "canary-first" in ($verdict.mitigations | get -o id | default []) {
    let problems = (wait-canaries $verdict.canaries $sha $started $deadline $poll)
    let outcome = { id: canary-first, ok: ($problems | is-empty), problems: $problems }
    let verdict = ($verdict | update outcomes { append $outcome })
    if ($problems | is-not-empty) {
      record-verdict $verdict canary-failed
      notify-landed $verdict
      error make { msg: $"main is at ($short), but the canary did not deploy it: ($problems | str join '; '). Switch no other host to it; fix forward with a new delivery." }
    }
    record-verdict $verdict delivered
    notify-landed $verdict
  } else {
    record-verdict $verdict delivered
    notify-landed $verdict
  }
  report-hosts $root $sha ($verdict | select deployed canaries destinations)
}
