#!/usr/bin/env nu

# Build a concise markdown reference from the pruned JSON.
export def main [
  --in_file: string = ".copilot/modalkit-rustdoc/modalkit-pruned.json"
  --out_file: string = ".copilot/modalkit-rustdoc/modalkit-api.md"
] {
  let rows = (do { open $in_file })

  let header = ([
    "# modalkit API (reedline Helix subset)\n\n"
    "Generated from docs.rs rustdoc JSON.\n\n"
    "Symbols imported in src/edit_mode/helix.rs:\n"
    "- TerminalKey\n- BindingMachine\n- EdgeEvent\n- EdgeRepeat\n- EmptyKeyState\n"
    "- InputBindings\n- InputKey\n- ModalMachine\n- Mode\n- ModeKeys\n\n"
  ] | str join "")

  let body = (
    $rows
    | sort-by name source
    | each {|r|
        let docs = ($r.docs | lines | first | default "")
        let p = ($r.path? | default "unknown")
        ([
          $"## ($r.name)\n"
          $"- kind: ($r.kind)\n"
          $"- source: ($r.source)@($r.crate_version)\n"
          $"- path: ($p)\n"
          (if ($docs | str length) > 0 { $"- docs: ($docs)\n" } else { "" })
        ] | str join "")
      }
    | str join "\n"
  )

  mkdir ($out_file | path dirname)
  ([ $header $body ] | str join "" | save -f $out_file)
  print $"wrote: ($out_file)"
}
