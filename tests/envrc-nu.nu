# envrc-nu's decisions and approvals, against throwaway projects:
#   nu --no-config-file tests/envrc-nu.nu nushell/envrc-nu.nu
#
# The prompt hooks themselves need an interactive shell; this covers what
# they decide: which module a project offers, whether it is approved, and
# whether the overlay should load, reload, or unload.

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
  let allow = ($tmp | path join allow)
  let a = ($tmp | path join a)
  let b = ($tmp | path join b)
  mkdir ($a | path join sub) $b
  "export def which-project [] { 'a' }\n" | save ($a | path join .envrc.nu)
  "export-env { $env.FROM_B = 'b' }\n" | save ($b | path join .envrc.nu)

  # `source` needs a literal path, so each case runs in its own nu, outside
  # any project direnv may have loaded for the caller.
  let run = {|code: string, pwd?: path|
    let result = (
      with-env {ENVRC_NU_ALLOW_DIR: $allow} {
        ^nu --no-config-file -c $"source '($script)'\nhide-env --ignore-errors DIRENV_DIR\ncd '($pwd | default $tmp)'\n($code) | to nuon" | complete
      }
    )
    if $result.exit_code == 0 { $result.stdout | from nuon } else { {error: ($result.stderr | str trim)} }
  }
  let offered = {|root: path| do $run $"envrc-nu-offer '($root)' | select --optional allowed exports_env" }

  mut failures = []

  $failures ++= (expect "no module at a root" (do $run $"envrc-nu-offer '($tmp)'") null)
  $failures ++= (expect "a new module is blocked" (do $offered $a) {allowed: false, exports_env: false})

  do $run $"envrc-nu allow '($a)'" | ignore
  $failures ++= (expect "allow approves it" (do $offered $a) {allowed: true, exports_env: false})

  "export def which-project [] { 'edited' }\n" | save --force ($a | path join .envrc.nu)
  $failures ++= (expect "an edit blocks it again" (do $offered $a) {allowed: false, exports_env: false})

  do $run "envrc-nu allow" ($a | path join sub) | ignore
  $failures ++= (expect "allow finds the module above the current directory" (do $offered $a) {allowed: true, exports_env: false})

  do $run $"with-env {DIRENV_DIR: '-($a)'} { envrc-nu deny }" | ignore
  $failures ++= (expect "deny revokes the approval for direnv's root" (do $offered $a) {allowed: false, exports_env: false})

  $failures ++= (expect "a module with export-env is flagged" (do $offered $b) {allowed: false, exports_env: true})
  let refused = (do $run $"envrc-nu allow '($b)'")
  $failures ++= (expect "allow refuses export-env" ($refused.error? | default "" | str contains "export-env") true)

  let offer = {|root: string, sha: string, allowed: bool, exports_env: bool|
    {root: $root, sha: $sha, allowed: $allowed, exports_env: $exports_env}
  }
  let loaded_a = {root: "a", sha: "1"}
  let cases = [
    [name loaded offer expected];
    ["nothing to do" null null ""]
    ["load an approved module" null (do $offer "a" "1" true false) "load"]
    ["keep the loaded module" $loaded_a (do $offer "a" "1" true false) ""]
    ["reload an approved edit" $loaded_a (do $offer "a" "2" true false) "reload"]
    ["switch projects" $loaded_a (do $offer "b" "1" true false) "reload"]
    ["unload when direnv leaves" $loaded_a null "unload"]
    ["unload for a blocked module" $loaded_a (do $offer "b" "1" false false) "unload"]
    ["never load export-env" null (do $offer "a" "1" true true) ""]
  ]
  for case in $cases {
    let actual = (do $run $"envrc-nu-action ($case.loaded | to nuon) ($case.offer | to nuon)")
    $failures ++= (expect $"action: ($case.name)" $actual $case.expected)
  }

  rm --recursive --force $tmp
  if ($failures | is-not-empty) {
    error make {msg: $"($failures | length) envrc-nu checks failed"}
  }
}
