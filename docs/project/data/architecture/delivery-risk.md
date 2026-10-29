---
type: architecture
description: luvus-deliver judges each delivery's risk before pushing; code works out which hosts it reaches from Den, Jev judges what it changes, and a high-risk delivery waits for the owner's approval of that exact commit.
generated:
  by: claude-code
  at: 2026-10-29T10:00:00Z
sources:
- id: deliver
  resource: tools/luvus-deliver.nu
  title: The classification, the approval, and the ledger
- id: reach
  resource: tools/den-reach.nix
  title: Which aspects each host's system and each home includes
- id: questions
  resource: jev/questions.nuon
  title: The delivery_risk questions and thresholds
- id: tests
  resource: tests/luvus-deliver.nu
  title: The nushell-luvus-deliver check
- id: agents
  resource: AGENTS.md
  title: The Delivery section
---

# Delivery risk

A reference architecture for fleets of coding agents routes each change through
a risk classifier: a low-risk change lands and is reviewed afterwards, a
high-risk one waits for review first. This repository had the inputs for one,
the risk and reviewer metadata of each aspect and each host's policy, but
nothing read them per change; whether a delivery needed the owner was the
delivering agent's judgment of the rule in `AGENTS.md`. On 2026-10-29 the author
chose Jev as the classifier.

- Code gathers the facts. Each changed file is traced through the relative paths
  the repository's Nix files name, up to the Den aspects that import it, and
  `tools/den-reach.nix` evaluates which aspects every host's system and every
  home includes, conditional includes among them, in about 0.2 seconds. A
  `flake.lock` change reaches what uses the inputs it updates; a Nix file whose
  two versions parse the same changed only comments and layout and reaches
  nothing.
- Jev judges what the change does: three Nouls (boot or storage, secrets or
  keys, access to a host or to main) and a five-level breakage Score. It reads
  the clipped diff without secrets, credential lines, documentation, or
  comment-only edits, which describe access or storage without changing either,
  and each file's policy risk: the highest risk `den/policy.nix` gives an aspect
  the file reaches.
- Code decides. High risk is a concern Noul at or above `min_concern`, breakage
  at or above `max_breakage`, a path under `secrets/`, `hosts/`, or
  `.github/rulesets/`, a change to the classifier or its `delivery_risk`
  questions (the installed classifier judges a delivery, so one that rewrote it
  would otherwise judge every delivery after it unseen), several deployed hosts
  once breakage reaches `several_hosts_min_breakage` or through configuration
  the policy rates high or critical, or anything that could not be judged. Low
  is no host reached; the rest is medium. A high-risk delivery stops before
  anything is pushed until `--approve` names the exact commit, never a branch.
  Every verdict is appended to `~/.local/state/luvus-deliver/risk.jsonl`.
- The thresholds were set on 20 deliveries of 2026-10-20 to 2026-10-29: 8 high
  (the ruleset, secret deletions, the Discord digest, the move to luvus, a new
  trusted cache, and three impermanence edits), 9 medium, and 3 low. Two of the
  first verdicts were wrong and fixed in the questions: a formatting job in
  GitHub Actions read as a required check, and trusting a binary cache's key
  read as routine. The fix to the staged switch's watch, which reaches every
  host through deployment configuration, was medium until policy risk counted,
  and adding an input that renumbered the lock's nodes counted unchanged inputs
  as updated until locks were compared by content.

Rejected: a table of path globs to risk levels next to `den/policy.nix`, which
was the first proposal (the author preferred Jev's judgment to rules to
maintain); a hand-kept map of aspects to hosts (Den already knows, and the map
would drift); asking Jev which hosts a change reaches (code can compute it
exactly); counting every change to several hosts as high, as `AGENTS.md` stated
the rule (niri and shell edits reach both asus and homelab, so nearly every
delivery would wait for approval); and approving by branch name (an approval
would carry over to commits merged after it).
