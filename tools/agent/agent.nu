# Structured execution API for humans and coding agents.
#
# This is an execution API and policy boundary, not a security sandbox. An
# interactive Nushell user can still invoke arbitrary external commands.

let AGENT_DEFAULT = {
    mode: "interactive"
    dry_run: false
    session: null
    approval: "normal"
}

let AGENT_POLICY = [
    {capability: "jj.read", effect: "allow"}
    {capability: "jj.write", effect: "ask"}
    {capability: "nix.eval", effect: "allow"}
    {capability: "nix.build", effect: "allow"}
    {capability: "nix.rebuild-test", effect: "allow"}
    {capability: "nix.rebuild-switch", effect: "ask"}
    {capability: "filesystem.read", effect: "allow"}
    {capability: "filesystem.write", effect: "ask"}
    {capability: "system.reboot", effect: "deny"}
]

def _agent-context [] {
    $env.AGENT? | default $AGENT_DEFAULT
}

def _agent-policy-effect [capability: string] {
    let entry = ($AGENT_POLICY | where capability == $capability | first)
    if $entry == null { "deny" } else { $entry.effect }
}

def _agent-plan-result [plan: record, execution: string, success: bool, reason: string, result?: record] {
    let base = {
        plan_id: $plan.id
        operation: $plan.operation
        capability: $plan.capability
        backend: $plan.backend
        execution: $execution
        success: $success
        exit_code: null
        started_at: (date now | format date "%+")
        ended_at: (date now | format date "%+")
        cwd: $plan.cwd
        stdout: ""
        stderr: ""
        reason: $reason
    }
    if $result == null { $base } else { $base | merge $result }
}

def _agent-describe [operation: string, args: record] {
    let common = {
        id: (random uuid)
        operation: $operation
        args: $args
        cwd: (pwd)
        created_at: (date now | format date "%+")
        status: "planned"
        approved: false
    }
    match $operation {
        "repo.status" => ($common | merge {capability: "jj.read", backend: "jj", argv: ["jj" "status"]})
        "repo.log" => ($common | merge {capability: "jj.read", backend: "jj", argv: ["jj" "log" "--no-pager" "--color" "never" "-n" "20"]})
        "repo.diff" => ($common | merge {capability: "jj.read", backend: "jj", argv: ["jj" "diff" "--no-pager" "--color" "never"]})
        "dev.check" => ($common | merge {capability: "nix.eval", backend: "nix", argv: ["nix" "flake" "check" "path:."]})
        "nix.check" => ($common | merge {capability: "nix.eval", backend: "nix", argv: ["nix" "flake" "check" "path:."]})
        "dev.build" => {
            let target = ($args.target? | default "path:.#homeConfigurations.schlich.activationPackage")
            $common | merge {capability: "nix.build", backend: "nix", argv: ["nix" "build" $target]}
        }
        _ => (error make {msg: $"Unknown agent operation: ($operation)"})
    }
}

def _agent-valid-plan [plan: any] {
    if not (($plan | describe) | str starts-with "record") { return false }
    let required = [id operation capability backend cwd status argv]
    ($required | all {|field|
        let value = (try { $plan | get $field } catch { null })
        $value != null
    })
}

def _agent-execute [plan: record] {
    let result = (match $plan.operation {
        "repo.status" => (do { cd $plan.cwd; ^jj status --no-pager --color never | complete })
        "repo.log" => (do { cd $plan.cwd; ^jj log --no-pager --color never -n 20 | complete })
        "repo.diff" => (do { cd $plan.cwd; ^jj diff --no-pager --color never | complete })
        "dev.check" | "nix.check" => (do { cd $plan.cwd; ^nix flake check path:. | complete })
        "dev.build" => (do { cd $plan.cwd; ^nix build ($plan.argv | last) | complete })
        _ => (error make {msg: $"No backend for operation: ($plan.operation)"})
    })
    {
        exit_code: $result.exit_code
        success: ($result.exit_code == 0)
        started_at: (date now | format date "%+")
        ended_at: (date now | format date "%+")
        stdout: $result.stdout
        stderr: $result.stderr
    }
}

export def "agent session show" [] {
    let context = (_agent-context)
    {
        mode: $context.mode
        dry_run: ($context.dry_run | default false)
        session: ($context.session? | default null)
        workspace: (pwd)
        approval: ($context.approval | default "normal")
    }
}

export def "agent session new" [--name: string] {
    let session_name = ($name | default (date now | format date "%Y%m%d-%H%M%S"))
    let context = (_agent-context)
    $env.AGENT = ($context | merge {
        session: {
            name: $session_name
            workspace: (pwd)
            created_at: (date now | format date "%+")
        }
    })
    agent session show
}

export def "agent session dry-run" [enabled?: bool] {
    let current = (_agent-context)
    let value = ($enabled | default (not ($current.dry_run | default false)))
    $env.AGENT = ($current | upsert dry_run $value)
    agent session show
}

export def "agent policy" [capability?: string] {
    if $capability == null {
        $AGENT_POLICY
    } else {
        $AGENT_POLICY | where capability == $capability | first
    }
}

export def "agent plan" [operation: string, args?: record] {
    _agent-describe $operation ($args | default {})
}

export def "agent approve" [plan: record] {
    if not (_agent-valid-plan $plan) {
        return {
            success: false
            status: "invalid"
            reason: "malformed-plan"
        }
    }
    $plan | upsert approved true | upsert status "approved"
}

export def "agent run" [plan: record --dry-run] {
    if not (_agent-valid-plan $plan) {
        return {
            success: false
            execution: "rejected"
            reason: "malformed-plan"
        }
    }
    let effect = (_agent-policy-effect $plan.capability)
    let context = (_agent-context)
    let dry_run = ($dry_run or ($context.dry_run | default false))
    if $effect == "deny" {
        _agent-plan-result $plan "rejected" false "policy-deny"
    } else if $effect == "ask" and not ($plan.approved | default false) {
        _agent-plan-result $plan "blocked" false "approval-required"
    } else if $dry_run {
        _agent-plan-result $plan "skipped" true "dry-run"
    } else {
        _agent-plan-result $plan "executed" true "" (_agent-execute $plan)
    }
}

export def "agent repo status" [] { agent run (agent plan "repo.status" {}) }
export def "agent repo log" [] { agent run (agent plan "repo.log" {}) }
export def "agent repo diff" [] { agent run (agent plan "repo.diff" {}) }
export def "agent dev check" [] { agent run (agent plan "dev.check" {}) }
export def "agent dev build" [target?: string] {
    agent run (agent plan "dev.build" {target: ($target | default "path:.#homeConfigurations.schlich.activationPackage")})
}

