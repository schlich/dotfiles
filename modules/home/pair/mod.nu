# Code-mode operations for Nushell workspaces.
source runtime.nu
source inspect.nu

def main [command: string, ...args: string] {
    match $command {
        "eval" => { pair-eval ($args | str join " ") }
        "inspect" => {
            if ($args | is-empty) { error make {msg: "usage: pair inspect <target> [operation] [amount]"} }
            if ($args | length) == 1 { pair-inspect $args.0 } else if ($args | length) == 2 { pair-inspect $args.0 $args.1 } else { pair-inspect $args.0 $args.1 ($args.2 | into int) }
        }
        "add" => { if ($args | length) < 2 { error make {msg: "usage: pair add <unit> <source>"} }; pair-add $args.0 $args.1 }
        "promote" => { if ($args | length) < 2 { error make {msg: "usage: pair promote <scratch-id> <unit>"} }; pair-promote $args.0 $args.1 }
        "run" => { if ($args | is-empty) { error make {msg: "usage: pair run <unit>"} }; pair-run $args.0 }
        "check" => { pair-check }
        "status" => { pair-status }
        _ => { error make {msg: $"unknown pair command: ($command)"} }
    }
}
