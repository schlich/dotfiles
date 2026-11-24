# Watch nixpkgs and upstream for the packages this home works around
# (dotfiles.nixpkgsWatch in modules/home/nix/nixpkgs-watch.nix), so each
# workaround goes once nixpkgs or upstream catches up.
#
#   nixpkgs-watch                       the last report
#   nixpkgs-watch check                 ask now and print what changed
#   nixpkgs-watch check --notify        the same as desktop notifications
#   nixpkgs-watch check --queue-tasks   also queue a luvus task for each
#                                       workaround that can go (the timer)
#   nixpkgs-watch coverage DIR FILE     the workarounds in DIR's Nix files
#                                       that FILE's declarations miss
#
# The wrapper sets NIXPKGS_WATCH_STATUS (each entry with the version the
# locked nixpkgs ships and its input's locked revision, written at build
# time), NIXPKGS_WATCH_NH, and NIXPKGS_WATCH_NOTIFY. Every other lookup runs
# only when the wrapper sets its command:
#
#   NIXPKGS_WATCH_JEV and   Jev judges the pull requests that only mention a
#   NIXPKGS_WATCH_QUESTIONS package
#   NIXPKGS_WATCH_GH        whether an entry's upstream fix is merged and
#                           released, and whether a local build's upstream
#                           has a flake.nix
#   NIXPKGS_WATCH_NIX       whether upstream's own build of an input is in a
#                           public binary cache
#   NIXPKGS_WATCH_CURL      whether upstream publishes on FlakeHub
#   NIXPKGS_WATCH_LUVUS     queues the tasks, run from NIXPKGS_WATCH_REPO,
#                           with NIXPKGS_WATCH_GATE as their gate

const channels = [nixpkgs-unstable nixos-unstable]

# Caches anyone may substitute from; a flake's nixConfig can name more.
const public_caches = [https://cache.nixos.org https://cache.flakehub.com]

def state-dir [] {
  $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join nixpkgs-watch
}

def has [tool: string]: nothing -> bool {
  $env | get --optional $"NIXPKGS_WATCH_($tool)" | is-not-empty
}

def last-line [text: string]: nothing -> string {
  $text | str trim | lines | last | default ""
}

# nh formats errors with a `Location:` footer; take the `Error:` line when present.
def nh-error [text: string]: nothing -> string {
  let lines = ($text | ansi strip | lines | each { str trim } | where { is-not-empty })
  $lines | where {|line| $line | str starts-with "Error:" } | get --optional 0 | default ($lines | last | default "")
}

# `nh search prs --json` emits `{ results: [{ number, title, state, reachability }] }`
# where each reachability entry has `branch` and `status` ("contains" | "missing" | "unknown").
export def parse-nh-prs []: string -> list<record> {
  let raw = ($in | str trim)
  if ($raw | is-empty) { return [] }
  $raw
  | from json
  | get results
  | each {|pr|
      {
        title: $pr.title
        status: $pr.state
        number: $pr.number
        reached: (
          $pr.reachability?
          | default []
          | where {|r| $r.status == "contains" and ($r.branch =~ '^nix(os|pkgs)-') }
          | each {|r| $r.branch }
        )
      }
    }
}

# A package's own pull requests, as nixpkgs titles them ("pkg: 1.0 -> 1.1",
# "pkg: init at 1.0"); `nh search prs` also returns anything that mentions it.
# Backports target release branches, which this flake does not follow.
export def own-prs [package: string]: list<record> -> list<record> {
  where {|pr| $pr.title | str starts-with $"($package):" }
  | each {|pr| $pr | insert landed ($pr.reached | any {|branch| $branch in $channels }) }
}

# The rest of `nh search prs`'s results, minus backports: pull requests that mention the
# package without being its own, such as a rename, a treewide change, or a
# dependency's update.
export def other-prs [package: string]: list<record> -> list<record> {
  where {|pr| not ($pr.title | str starts-with $"($package):") and not ($pr.title | str starts-with "[Backport") }
  | each {|pr| $pr | insert landed ($pr.reached | any {|branch| $branch in $channels }) }
}

# Each other pull request with `related`, Jev's probability from its title
# that it bears on the workaround. A verdict in the seen list is reused, so
# each pull request is asked about once; one Jev could not give stays null
# and is asked again next run.
def judge-related [entry: record, prs: list<record>, seen: list<record>]: nothing -> list<record> {
  let config = (open $env.NIXPKGS_WATCH_QUESTIONS).nixpkgs_watch
  $prs | each {|pr|
    let known = ($seen | where key == $"($entry.package)#($pr.number)" | get --optional 0.related)
    let related = if $known != null { $known } else {
      let request = {
        state: { pr: ($pr | select title status), workaround: ($entry | select package reason) }
        questions: $config.questions
      }
      let run = ($request | to json --raw | run-external $env.NIXPKGS_WATCH_JEV ask | complete)
      if $run.exit_code == 0 { ($run.stdout | from json).answers.bears_on_workaround.noul } else { null }
    }
    $pr | insert related $related
  }
}

# A related pull request seen for the first time, or reaching unstable.
export def related-events [entry: record, related: list<record>, seen: list<record>]: nothing -> list<record> {
  $related | each {|pr|
    let before = ($seen | where key == $"($entry.package)#($pr.number)" | get --optional 0)
    if $before == null {
      { package: $entry.package, kind: related, text: $"#($pr.number) may bear on the workaround \(($pr.status)\): ($pr.title)" }
    } else if $pr.landed and not $before.landed {
      { package: $entry.package, kind: landed, text: $"#($pr.number) reached ($pr.reached | where {|b| $b in $channels } | str join ', '): ($pr.title). Check whether it ends the workaround: ($entry.reason)" }
    }
  } | compact
}

# What is new since the last run: a pull request opened, one reaching the
# unstable channels, or the locked nixpkgs now shipping what the workaround
# provides.
export def events [entry: record, prs: list<record>, seen: list<record>]: nothing -> list<record> {
  let pr_events = (
    $prs | each {|pr|
      let key = $"($entry.package)#($pr.number)"
      let before = ($seen | where key == $key | get --optional 0)
      if $before == null and $pr.status == "open" {
        { package: $entry.package, kind: opened, text: $"#($pr.number) opened: ($pr.title)" }
      } else if $pr.landed and ($before == null or not $before.landed) {
        { package: $entry.package, kind: landed, text: $"#($pr.number) reached ($pr.reached | where {|b| $b in $channels } | str join ', '): ($pr.title). `nix flake update nixpkgs` picks it up." }
      }
    } | compact
  )
  let ready_key = $"($entry.package)@($entry.nixpkgs)"
  let ready = if $entry.ready and ($seen | where key == $ready_key | is-empty) {
    [{ package: $entry.package, kind: ready, text: (ready-text $entry) }]
  } else { [] }
  $pr_events | append $ready
}

def ready-text [entry: record]: nothing -> string {
  $"The locked nixpkgs ships ($entry.package) ($entry.nixpkgs | default 'now'). Remove the workaround: ($entry.reason)"
}

# The seen list after this run: every pull request's state and each ready
# version, so a change is reported once.
export def remember [entry: record, prs: list<record>, judged: list<record> = []]: nothing -> list<record> {
  $prs
  | each {|pr| { key: $"($entry.package)#($pr.number)", status: $pr.status, landed: $pr.landed } }
  | append ($judged | where related != null | each {|pr| { key: $"($entry.package)#($pr.number)", status: $pr.status, landed: $pr.landed, related: $pr.related } })
  | append (if $entry.ready { [{ key: $"($entry.package)@($entry.nixpkgs)", status: ready, landed: true }] } else { [] })
}

# An upstream fix's URL as its repository, kind (pull or commit), and id.
export def parse-fix [url: string]: nothing -> any {
  let found = ($url | parse --regex '^https://github\.com/(?<repo>[^/]+/[^/]+)/(?<kind>pull|commit)/(?<id>[0-9A-Za-z]+)')
  if ($found | is-empty) { null } else { $found.0 }
}

# The tags a project may give the release of `version`.
export def release-tags [package: string, version: string]: nothing -> list<string> {
  [$"v($version)" $version $"($package)-v($version)" $"($package)-($version)" $"rust-v($version)"] | uniq
}

# Where an entry's upstream fix stands: a pull request is open, closed,
# merged, or released; a commit is unreleased or released. Released means in
# the release nixpkgs ships when it ships the package, and otherwise in the
# input's locked revision, as for a fix to upstream's own flake. A fork's
# commit is never in nixpkgs' release, so it stays unreleased.
def fix-state [entry: record]: nothing -> record {
  let fix = (parse-fix $entry.fix)
  if $fix == null {
    return { state: null, error: $"fix is not a GitHub pull request or commit URL: ($entry.fix)" }
  }
  let gh = $env.NIXPKGS_WATCH_GH
  let sha = if $fix.kind == pull {
    let run = (^$gh api $"repos/($fix.repo)/pulls/($fix.id)" | complete)
    if $run.exit_code != 0 { return { state: null, error: (last-line $run.stderr) } }
    let pr = ($run.stdout | from json)
    if ($pr.merged_at? | is-empty) {
      return { state: (if $pr.state == open { "open" } else { "closed" }), error: null }
    }
    $pr.merge_commit_sha
  } else { $fix.id }
  let refs = if ($entry.nixpkgs? | is-not-empty) {
    release-tags $entry.package $entry.nixpkgs
  } else if ($entry.rev? | is-not-empty) {
    [$entry.rev]
  } else { [] }
  let released = ($refs | any {|ref|
    let run = (^$gh api $"repos/($fix.repo)/compare/($sha)...($ref)" --jq .status | complete)
    $run.exit_code == 0 and ($run.stdout | str trim) in [ahead identical]
  })
  { state: (if $released { "released" } else if $fix.kind == pull { "merged" } else { "unreleased" }), error: null }
}

# What changed about an entry's upstream fix since the last run.
export def fix-events [entry: record, fix: record, seen: list<record>]: nothing -> list<record> {
  if $fix.state == null { return [] }
  let before = ($seen | where key == $"($entry.package)!fix" | get --optional 0.status)
  if $before == $fix.state { return [] }
  let from_input = ($entry.nixpkgs? | is-empty) and ($entry.rev? | is-not-empty)
  match $fix.state {
    "merged" => [{
      package: $entry.package
      kind: fix-merged
      text: $"($entry.fix) is merged upstream; the workaround can go once (if $from_input { $'`nix flake update ($entry.input)` takes it' } else { 'a release nixpkgs ships contains it' })."
    }]
    "released" => [{ package: $entry.package, kind: ready, text: (fix-text $entry) }]
    "closed" => [{
      package: $entry.package
      kind: fix-closed
      text: $"($entry.fix) was closed without merging; the workaround needs another way out: ($entry.reason)"
    }]
    _ => []
  }
}

def fix-text [entry: record]: nothing -> string {
  let where = if ($entry.nixpkgs? | is-not-empty) { $"nixpkgs' ($entry.package) ($entry.nixpkgs)" } else { $"The locked ($entry.input)" }
  $"($where) contains ($entry.fix). Remove the workaround: ($entry.reason)"
}

# The binary caches a flake.nix's nixConfig asks for.
export def substituters-in []: string -> list<string> {
  let text = $in
  let lists = ($text | parse --regex '(?s)substituters"?\s*=\s*\[(?<urls>[^\]]*)\]' | get urls)
  let strings = ($text | parse --regex 'substituters"?\s*=\s*"(?<urls>[^"]*)"' | get urls)
  $lists
  | append $strings
  | each {|urls| $urls | parse --regex '(?<url>https?://[^\s"]+)' | get url }
  | flatten
  | each { str trim --right --char '/' }
  | uniq
}

# Whether upstream's own build of an input, as upstream locks it, is in a
# public binary cache or one its flake.nix declares. This flake builds its
# own when the input follows this flake's nixpkgs.
def cache-state [entry: record]: nothing -> record {
  let nix = $env.NIXPKGS_WATCH_NIX
  let output = $"($entry.locked)#packages.($entry.system).($entry.attr).outPath"
  let eval = (^$nix eval --raw --option allow-import-from-derivation false $output | complete)
  if $eval.exit_code != 0 {
    return { checked: false, cache: null, error: (last-line $eval.stderr) }
  }
  let path = ($eval.stdout | str trim)
  let source = (^$nix flake prefetch --json $entry.locked | complete)
  let declared = if $source.exit_code == 0 {
    let flake = (($source.stdout | from json).storePath | path join flake.nix)
    if ($flake | path exists) { open --raw $flake | substituters-in } else { [] }
  } else { [] }
  let hit = (
    $public_caches
    | append $declared
    | uniq
    | where {|cache| (^$nix path-info --store $cache $path | complete).exit_code == 0 }
    | get --optional 0
  )
  { checked: true, cache: $hit, error: null }
}

export def cache-events [entry: record, cache: record, seen: list<record>]: nothing -> list<record> {
  if $cache.cache == null { return [] }
  if ($seen | where key == $"($entry.package)~cache" and status == $cache.cache | is-not-empty) { return [] }
  [{ package: $entry.package, kind: cached, text: (cache-text $entry $cache) }]
}

def cache-text [entry: record, cache: record]: nothing -> string {
  $"Upstream's own build of ($entry.input) is in ($cache.cache), but ($entry.input) follows this flake's nixpkgs, so its package builds here. Dropping `inputs.($entry.input).inputs.nixpkgs.follows`, trusting ($cache.cache) if nix.settings does not, and dropping any override of the package would substitute it. The workaround: ($entry.reason)"
}

# Whether a local build's upstream now publishes on FlakeHub or ships a
# flake.nix, either of which can replace building it here.
def upstream-state [entry: record]: nothing -> record {
  if ($entry.repo? | is-empty) { return { flakehub: null, flake: null } }
  let flakehub = if ($entry.onFlakehub? | default false) or not (has CURL) { null } else {
    let run = (^$env.NIXPKGS_WATCH_CURL --silent --output /dev/null --write-out '%{http_code}' $"https://api.flakehub.com/f/($entry.repo)" | complete)
    if $run.exit_code == 0 { ($run.stdout | str trim) == "200" } else { null }
  }
  let flake = if ($entry.input? | is-not-empty) or not (has GH) { null } else {
    (^$env.NIXPKGS_WATCH_GH api $"repos/($entry.repo)/contents/flake.nix" --jq .path | complete).exit_code == 0
  }
  { flakehub: $flakehub, flake: $flake }
}

export def upstream-events [entry: record, upstream: record, seen: list<record>]: nothing -> list<record> {
  let new = {|what| $seen | where key == $"($entry.package)~($what)" | is-empty }
  [
    (if $upstream.flakehub == true and (do $new flakehub) {
      { package: $entry.package, kind: flakehub, text: $"($entry.repo) publishes on FlakeHub \(https://flakehub.com/flake/($entry.repo)\), whose cache this flake trusts; taking it from there may end the build here." }
    })
    (if $upstream.flake == true and (do $new flake) {
      { package: $entry.package, kind: flake, text: $"($entry.repo) now ships a flake.nix; taking the package from it, and from a binary cache it declares, may end the build here." }
    })
  ] | compact
}

# The seen rows for the upstream checks. A check that did not run keeps
# what the last run saw, so its change is still reported once.
export def remember-upstream [entry: record, fix: record, cache: record, upstream: record, seen: list<record>]: nothing -> list<record> {
  let prior = {|suffix| $seen | where key == $"($entry.package)($suffix)" }
  let found = {|value suffix|
    if $value == true { [{ key: $"($entry.package)($suffix)", status: found, landed: true }] } else if $value == false { [] } else { do $prior $suffix }
  }
  [
    (if $fix.state != null { [{ key: $"($entry.package)!fix", status: $fix.state, landed: ($fix.state == released) }] } else { do $prior "!fix" })
    (if $cache.cache != null { [{ key: $"($entry.package)~cache", status: $cache.cache, landed: true }] } else if $cache.checked { [] } else { do $prior "~cache" })
    (do $found $upstream.flakehub "~flakehub")
    (do $found $upstream.flake "~flake")
  ] | flatten
}

# The luvus tasks an entry's state calls for: one per way its workaround can
# go, with its title, prompt, and the files it touches.
export def due-tasks [entry: record, fix: record, cache: record]: nothing -> list<record> {
  let files = ($entry.files? | default [])
  let paths = ($files | append (if ($entry.input? | is-not-empty) { [flake.nix flake.lock] } else { [] }) | uniq)
  let declared = $"Declared as dotfiles.nixpkgsWatch.($entry.name? | default $entry.package) in (if ($files | is-empty) { 'this repository' } else { $files | str join ', ' }); remove that entry with the workaround."
  let task = {|title text| { title: $title, prompt: $"($text)\n\n($declared)", paths: $paths } }
  [
    (if $entry.ready { do $task $"($entry.package): use nixpkgs' ($entry.package)" (ready-text $entry) })
    (if $fix.state == released { do $task $"($entry.package): drop the override, fixed upstream" (fix-text $entry) })
    (if $cache.cache != null { do $task $"($entry.package): substitute upstream's cached build" (cache-text $entry $cache) })
  ] | compact
}

# Whether a task already on the board does what a due task would: its title
# names the package and the same way out.
export def on-board [title: string, existing: list<string>]: nothing -> bool {
  let package = ($title | split row ':' | first)
  let way = if ($title =~ "nixpkgs'") { "nixpkgs'" } else if ($title =~ 'fixed upstream') { 'fixed upstream' } else { 'cached build' }
  let name = ($package | str replace --all --regex '([.+*?()\[\]{}|^$\\])' '\$1')
  $existing | any {|other|
    ($other | str contains $way) and ($other =~ $"\(^|[^A-Za-z0-9-]\)($name)\($|[^A-Za-z0-9-]\)")
  }
}

# Queues each due task that neither this watch nor anyone else has put on the
# board yet. A failed attempt is not recorded, so the next run tries again.
def queue-tasks [tasks: list<record>, dir: path]: nothing -> record {
  let file = ($dir | path join tasks.json)
  let filed = if ($file | path exists) { open $file } else { [] }
  let todo = ($tasks | where title not-in $filed)
  if ($todo | is-empty) { return { queued: [], skipped: [], error: null } }
  let repo = ($env.NIXPKGS_WATCH_REPO? | default $env.HOME)
  let cwd = if ($repo | path exists) { $repo } else { $env.HOME }
  let luvus = $env.NIXPKGS_WATCH_LUVUS
  let board = (do { cd $cwd; ^$luvus task list } | complete)
  if $board.exit_code != 0 { return { queued: [], skipped: [], error: (last-line $board.stderr) } }
  let existing = ($board.stdout | from json | get result.tasks.title)
  let results = ($todo | each {|task|
    if (on-board $task.title $existing) {
      { title: $task.title, done: true, queued: false, error: null }
    } else {
      let gate = if (has GATE) { [--gate $env.NIXPKGS_WATCH_GATE] } else { [] }
      let paths = if ($task.paths | is-empty) { [] } else { [--paths ...$task.paths] }
      let run = (do { cd $cwd; ^$luvus task add $task.title --prompt $task.prompt ...$gate ...$paths } | complete)
      { title: $task.title, done: ($run.exit_code == 0), queued: ($run.exit_code == 0), error: (if $run.exit_code != 0 { last-line $run.stderr }) }
    }
  })
  $filed | append ($results | where done | get title) | uniq | save --force $file
  {
    queued: ($results | where queued | get title)
    skipped: ($results | where {|r| $r.done and not $r.queued } | get title)
    error: ($results | where error != null | get --optional 0.error)
  }
}

# Lines of a Nix file that work around nixpkgs: packages from a flake input
# (with `input`), and local builds of upstream source and overrideAttrs.
export def sites []: string -> list<record> {
  $in | lines | enumerate | where {|line| not ($line.item | str trim | str starts-with '#') } | each {|line|
    let code = $line.item
    let from_packages = ($code | parse --regex 'inputs\.(?<name>[A-Za-z0-9_-]+)\.(?:packages|legacyPackages)\b' | get name)
    let from_source = (
      $code
      | parse --regex '(?:callPackage|import)\s*\(?\s*(?:"\$\{inputs\.(?<a>[A-Za-z0-9_-]+)\}|inputs\.(?<b>[A-Za-z0-9_-]+)\s*\+)'
      | each {|found| [$found.a $found.b] }
      | flatten
    )
    let inputs = ($from_packages | append $from_source | where {|name| ($name | is-not-empty) and $name not-in [nixpkgs self] } | uniq)
    let builds = ($code =~ '\b(buildRustPackage|buildGoModule|buildNpmPackage|buildPythonApplication|buildPythonPackage|buildDotnetModule|appimageTools\.wrapType2|fetchFromGitHub|fetchFromGitLab|fetchurl|fetchzip|fetchgit|fetchCrate|fetchPypi|overrideAttrs)\b')
    let text = ($code | str trim)
    $inputs
    | each {|name| { line: ($line.index + 1), input: $name, text: $text } }
    | append (if $builds and ($inputs | is-empty) { [{ line: ($line.index + 1), input: null, text: $text }] } else { [] })
  } | flatten
}

# The entry a file is named for: its name without "-package", or its
# directory's for default.nix and package.nix.
export def named-for [file: string]: nothing -> string {
  let parts = ($file | path parse)
  let stem = if $parts.stem in [default package] { $parts.parent | path basename } else { $parts.stem }
  $stem | str replace --regex '-package$' ''
}

# The workaround sites of a file that nothing covers. A flake input's
# package needs an entry with that `input`, or an exemption. A local build or
# overrideAttrs needs an entry declared in the file or named for it, or a
# comment: `# nixpkgs-watch: NAME, ...` naming entries declared elsewhere, or
# `# nixpkgs-watch: not a workaround: REASON`.
export def uncovered [file: string, declared: record]: string -> list<record> {
  let text = $in
  let names = ($declared.entries | columns)
  let inputs = ($declared.entries | values | each { $in.input? } | compact | append ($declared.exempt | columns))
  let markers = ($text | parse --regex '#\s*nixpkgs-watch:\s*(?<value>.*\S)' | get value)
  let unknown = (
    $markers
    | where {|marker| not ($marker | str starts-with 'not a workaround:') }
    | each { split row --regex '[,\s]+' }
    | flatten
    | where {|name| ($name | is-not-empty) and $name not-in $names }
  )
  let covered = (
    ($text =~ 'nixpkgsWatch(\.[A-Za-z0-9_-]+)*\s*=')
    or ((named-for $file) in $names)
    or (($markers | is-not-empty) and ($unknown | is-empty))
  )
  $text
  | sites
  | where {|site| if $site.input != null { $site.input not-in $inputs } else { not $covered } }
  | each {|site|
      $site | insert file $file | insert why (
        if $site.input != null {
          $"no entry takes input ($site.input), and dotfiles.nixpkgsWatchExempt does not name it"
        } else { "no entry is declared in or named for this file, and no comment covers it" }
      )
    }
  | append ($unknown | each {|name| { line: null, input: null, text: "", file: $file, why: $"its nixpkgs-watch comment names ($name), which no entry declares" } })
}

def notify [summary: string, body: string] {
  try { ^$env.NIXPKGS_WATCH_NOTIFY --app-name nixpkgs-watch $summary $body } catch { }
}

def show [report: record] {
  print $"Checked ($report.checked | into datetime | date humanize), PRs from the last ($report.days) days."
  let prs = {|numbers| $numbers | each { $"#($in)" } | str join " " }
  print (
    $report.entries
    | each {|entry|
        {
          package: $entry.package
          pinned: ($entry.version | default "-")
          nixpkgs: ($entry.nixpkgs | default "absent")
          "drop workaround": (if $entry.ready { "yes" } else { "" })
          "open PRs": (do $prs $entry.open)
          "in unstable": (do $prs $entry.landed)
          related: (do $prs ($entry.related? | default []))
          upstream: ($entry.upstream? | default [] | str join ", ")
          error: ([$entry.error ($entry.upstream_error? | default null)] | compact | str join "; ")
        }
      }
    | table --index false
  )
  if ($report.events | is-not-empty) {
    print "Since the run before:"
    $report.events | each {|event| print $"  ($event.package): ($event.text)" } | ignore
  }
  let queued = ($report.tasks?.queued? | default [])
  if ($queued | is-not-empty) {
    print "Queued on the luvus board:"
    $queued | each {|title| print $"  ($title)" } | ignore
  }
}

def main [] {
  let report = (state-dir | path join report.json)
  if not ($report | path exists) {
    print "No report yet; run `nixpkgs-watch check`."
    return
  }
  show (open $report)
}

def "main check" [
  --days: int = 30  # how far back `nh search prs` searches; PRs are tracked from then on
  --notify          # report changes as desktop notifications
  --queue-tasks     # queue a luvus task for each workaround that can go
] {
  let dir = (state-dir)
  mkdir $dir
  let seen_file = ($dir | path join seen.json)
  let first_run = not ($seen_file | path exists)
  let seen = if $first_run { [] } else { open $seen_file }
  let report_file = ($dir | path join report.json)
  let previous = if ($report_file | path exists) { open $report_file } else { { entries: [], tasks: null } }
  let previous_errors = ($previous.entries | where error != null | select package error)
  let use_jev = (has JEV) and (has QUESTIONS)
  let min_related = if $use_jev { (open $env.NIXPKGS_WATCH_QUESTIONS).nixpkgs_watch.min_related } else { 1.0 }

  let gh_token = if ($env.GH_TOKEN? | is-not-empty) {
    $env.GH_TOKEN
  } else if (has GH) {
    let tok = (^$env.NIXPKGS_WATCH_GH auth token | complete)
    if $tok.exit_code == 0 { $tok.stdout | str trim } else { null }
  } else {
    null
  }

  let results = (
    open $env.NIXPKGS_WATCH_STATUS
    | transpose name entry
    | each {|item|
        let entry = $item.entry
        let run = if ($gh_token | is-not-empty) {
          with-env { GH_TOKEN: $gh_token } {
            ^$env.NIXPKGS_WATCH_NH search prs --days $days --json $entry.package | complete
          }
        } else {
          ^$env.NIXPKGS_WATCH_NH search prs --days $days --json $entry.package | complete
        }
        let found = if $run.exit_code == 0 { $run.stdout | parse-nh-prs } else { [] }
        let prs = ($found | own-prs $entry.package)
        let judged = if $use_jev { judge-related $entry ($found | other-prs $entry.package) $seen } else { [] }
        let related = ($judged | where related != null | where related >= $min_related)
        let fix = if ($entry.fix? | is-not-empty) and (has GH) { fix-state $entry } else { { state: null, error: null } }
        let cache = if ($entry.follows? | default false) and ($entry.locked? | is-not-empty) and (has NIX) {
          cache-state $entry
        } else { { checked: false, cache: null, error: null } }
        let upstream = (upstream-state $entry)
        {
          entry: $entry
          prs: $prs
          judged: $judged
          related: $related
          fix: $fix
          cache: $cache
          upstream: $upstream
          error: (if $run.exit_code != 0 { nh-error $run.stderr })
          events: (
            (if $run.exit_code == 0 { events $entry $prs $seen | append (related-events $entry $related $seen) } else { [] })
            | append (fix-events $entry $fix $seen)
            | append (cache-events $entry $cache $seen)
            | append (upstream-events $entry $upstream $seen)
          )
        }
      }
  )

  # A failed search keeps what was seen, so its changes still show next time.
  let failed = ($results | where error != null | get entry.package)
  let kept = ($seen | where {|row| ($row.key =~ '[#@]') and (($row.key | split row --regex '[#@]' | first) in $failed) })
  $results
  | each {|r|
      (if $r.error == null { remember $r.entry $r.prs $r.judged } else { [] })
      | append (remember-upstream $r.entry $r.fix $r.cache $r.upstream $seen)
    }
  | flatten
  | append $kept
  | save --force $seen_file

  let tasks = if $queue_tasks and (has LUVUS) {
    queue-tasks ($results | each {|r| due-tasks $r.entry $r.fix $r.cache } | flatten) $dir
  } else { null }

  let events = ($results | get events | flatten)
  let report = {
    checked: (date now | format date "%+")
    days: $days
    entries: ($results | each {|r|
      $r.entry | select package version nixpkgs ready reason | merge {
        open: ($r.prs | where status == open | get number)
        landed: ($r.prs | where landed | get number)
        related: ($r.related | get number)
        upstream: ([
          (if $r.fix.state != null { $"fix ($r.fix.state)" })
          (if $r.cache.cache != null { $"cached: ($r.cache.cache | url parse | get host)" })
          (if $r.upstream.flakehub == true { "on FlakeHub" })
          (if $r.upstream.flake == true { "has a flake" })
        ] | compact)
        error: $r.error
        upstream_error: ([$r.fix.error $r.cache.error] | compact | get --optional 0)
      }
    })
    events: $events
    tasks: $tasks
  }
  $report | save --force $report_file

  if $notify {
    if $first_run {
      let open = ($report.entries | get open | flatten | length)
      notify "nixpkgs-watch is on" $"Watching ($report.entries | length) packages; ($open) pull requests open. Run `nixpkgs-watch` for the report."
    } else {
      for event in $events { notify $"nixpkgs: ($event.package)" $event.text }
    }
    # A failure that persists is reported once, not every day.
    for r in ($results | where error != null) {
      if ($previous_errors | where package == $r.entry.package and error == $r.error | is-empty) {
        notify $"nixpkgs-watch: nh search prs failed for ($r.entry.package)" $r.error
      }
    }
    if $tasks != null {
      for title in $tasks.queued { notify "nixpkgs-watch queued a task" $title }
      if $tasks.error != null and $tasks.error != ($previous.tasks?.error? | default null) {
        notify "nixpkgs-watch could not queue a luvus task" $tasks.error
      }
    }
  } else {
    show $report
  }
}

# Fails, listing each workaround in DIR's Nix files that DECLARED's entries
# and exemptions do not cover. The flake check passes the repository's Nix
# files and the home's declarations.
def "main coverage" [
  root: path      # directory to search for Nix files
  declared: path  # JSON: { entries: { NAME: { package, input } }, exempt: { INPUT: REASON } }
] {
  let declared = (open $declared)
  let root = ($root | path expand)
  let files = (
    glob $"($root)/**/*.nix" --no-symlink --exclude ['**/.jj-workspaces/**' '**/.claude/**' '**/.git/**' '**/result*/**']
    | each { path relative-to $root }
    | where {|file| $file !~ '^(\.jj-workspaces|\.claude|templates)/' }
  )
  let missing = ($files | each {|file| open --raw ($root | path join $file) | uncovered $file $declared } | flatten)
  if ($missing | is-empty) {
    print $"Every workaround in ($files | length) Nix files has a watch."
    return
  }
  print ($missing | each {|site|
    let at = if $site.line != null { $"($site.file):($site.line)" } else { $site.file }
    $"($at): ($site.why)(if ($site.text | is-not-empty) { $"\n    ($site.text)" } else { '' })"
  } | str join "\n")
  print ([
    ""
    "Give each a way out: a dotfiles.nixpkgsWatch entry beside it (`input` names"
    "a flake input; an entry named for the file, such as foo for foo-package.nix,"
    "covers that file), a `# nixpkgs-watch: NAME` comment naming an entry declared"
    "elsewhere, `# nixpkgs-watch: not a workaround: REASON`, or, for a flake input"
    "of your own, dotfiles.nixpkgsWatchExempt (modules/home/nix/nixpkgs-watch.nix)."
  ] | str join "\n")
  error make --unspanned { msg: $"($missing | length) workarounds have no nixpkgs watch" }
}
