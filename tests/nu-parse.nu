# Parse every Nushell script given, as `nu-check` does, and fail on any that
# does not parse. Parsing needs no runtime, so this catches syntax errors in
# scripts that only run from a keybinding, hook, or service.
def main [...files: string] {
  let files = $files | path expand
  let failed = $files | where {|file| not (nu-check $file) }
  for file in $failed {
    try { nu-check --debug $file } catch {|err| print --stderr $err.rendered }
  }
  if ($failed | is-not-empty) {
    error make --unspanned {
      msg: $"($failed | length) of ($files | length) Nushell scripts do not parse: ($failed | str join ', ')"
    }
  }
  print $"All ($files | length) Nushell scripts parse."
}
