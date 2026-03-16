#!/usr/bin/env nu

# Prune rustdoc JSON down to the symbols used by reedline Helix mode.
export def main [
  --modalkit_json: string = ".copilot/modalkit-rustdoc/raw/modalkit-0.0.24.json"
  --keybindings_json: string = ".copilot/modalkit-rustdoc/raw/keybindings-0.0.2.json"
  --symbols_file: string = ".copilot/skills/modalkit-rustdoc/references/helix-symbols.txt"
  --out_file: string = ".copilot/modalkit-rustdoc/modalkit-pruned.json"
] {
  let targets = (open $symbols_file | lines | each {|x| $x | str trim } | where {|x| ($x | str length) > 0 })

  def extract [json_path: string, source: string, targets: list<string>] {
    let d = (open $json_path)

    $d.index
    | values
    | where {|item| ($item.name in $targets) }
    | each {|item|
        let kind = ($item.inner | columns | first)
        {
          source: $source
          crate_version: ($d.crate_version? | default "unknown")
          id: $item.id
          name: $item.name
          kind: $kind
          docs: ($item.docs? | default "")
          path: (
            $d.paths
            | values
            | where {|p| (($p.path | last) == $item.name) }
            | each {|p| $p.path | str join "::" }
            | first
          )
        }
      }
  }

  let pruned = ((extract $modalkit_json "modalkit" $targets) ++ (extract $keybindings_json "keybindings" $targets))

  mkdir ($out_file | path dirname)
  ($pruned | to json -i 2 | save -f $out_file)
  print $"wrote: ($out_file)"
}
