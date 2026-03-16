#!/usr/bin/env nu

# Fetch rustdoc JSON from docs.rs (zstd payload) and store decompressed copies.
export def main [
  --modalkit_version: string = "0.0.24"
  --keybindings_version: string = "0.0.2"
  --out_dir: string = ".copilot/modalkit-rustdoc/raw"
] {
  mkdir $out_dir

  let targets = [
    { crate: "modalkit", version: $modalkit_version }
    { crate: "keybindings", version: $keybindings_version }
  ]

  for t in $targets {
    let base = $"($t.crate)-($t.version)"
    let zst = ($out_dir | path join $"($base).json.zst")
    let json = ($out_dir | path join $"($base).json")
    let url = $"https://docs.rs/crate/($t.crate)/($t.version)/json"

    ^curl -fsSL $url -o $zst
    ^zstd -d -f $zst -o $json
    print $"fetched: ($json)"
  }
}
