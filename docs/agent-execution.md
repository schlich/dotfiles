# Agent execution layer

The `agent` Nushell module is a small, structured capability API for humans
and coding agents. It keeps the public interface stable while allowing the
backend to remain JJ, Nix, or a future project-specific implementation:

```text
selection -> plan -> policy -> approval -> execution -> result
```

## Commands

```nu
agent session new --name feature-a
agent session show
agent session dry-run true
agent policy
agent plan nix.check {}
agent approve $plan
agent run $plan --dry-run

agent repo status
agent repo log
agent repo diff
agent dev check
agent dev build
```

Plans and execution results are ordinary Nu records. Results include the plan
ID, operation, capability, backend, execution state, exit code, working
directory, and captured output where a backend ran.

The initial policy is declarative and uses `allow`, `ask`, and `deny`. Read
operations are allowed, write-oriented JJ/filesystem operations ask for an
explicit approval, and reboot is denied. `agent approve` marks a plan as
approved; it does not grant broader shell access.

Dry-run mode returns the plan with `execution: "skipped"` and never invokes the
backend. It can be enabled for the current Nushell process with
`agent session dry-run true` or selected per invocation with `agent run $plan
--dry-run`.

Session metadata currently records a name and the current directory. It does
not create, switch, or destroy JJ workspaces. This is deliberate: JJ already
enforces important workspace ownership rules, so a future workspace adapter
must first identify an unambiguous one-agent/one-workspace lifecycle and must
never reuse or destroy another task's workspace automatically.

This is an execution API and policy boundary, not a security sandbox. Nushell
users can still run arbitrary external commands, and a policy wrapper cannot
contain an agent that has unrestricted shell access. Hard containment remains a
future concern for deliberately restricted environments.

To add a capability, add a policy entry, describe its operation in
`agent/agent.nu`, and add a backend branch that returns the standard result
record. Prefer machine-readable backend output when the tool provides it;
otherwise preserve stdout/stderr rather than inventing structure by parsing
human-oriented text.

