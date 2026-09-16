use std/assert

source ../tools/agent/agent.nu

let allow = (agent policy "jj.read").effect
assert equal $allow "allow"
let ask = (agent policy "jj.write").effect
assert equal $ask "ask"
let deny = (agent policy "system.reboot").effect
assert equal $deny "deny"

let plan = (agent plan "nix.check" {})
assert equal $plan.status "planned"
let dry = (agent run $plan --dry-run)
assert equal $dry.execution "skipped"
assert equal $dry.reason "dry-run"

let malformed = (agent run {operation: "nix.check"})
assert equal $malformed.reason "malformed-plan"
