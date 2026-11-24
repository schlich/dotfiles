---
type: architecture
description: luvus-deliver works out each delivery's risk before pushing from which hosts it reaches and which paths it changes, and a high-risk delivery runs the mitigations its verdict names instead of waiting for the owner (since 2026-11-23); Jev judged what it changed until 2026-11-21.
generated:
  by: claude-code/opus-5.5
  at: 2026-11-21T05:00:00Z
sources:
- id: deliver
  resource: tools/luvus-deliver.nu
  title: The classification, the mitigations, and the ledger
- id: reach
  resource: tools/den-reach.nix
  title: Which aspects each host's system and each home includes
- id: tests
  resource: tests/luvus-deliver.nu
  title: The nushell-luvus-deliver check
- id: agents
  resource: AGENTS.md
  title: The Delivery section
---

# Delivery risk

*Changed 2026-11-23: the owner asked that high-risk deliveries stop holding up
automation. Nothing waits for approval and `--approve` is gone. The same
triggers now name mitigations, and a failed mitigation fails the delivery like a
failed check:*

- *`secrets/` or `hosts/login-keys.nix`: `secret-recipients`, before the push.
  Every age file is declared in `secrets/secrets.nix`, and the ssh tags in its
  header match exactly the keys declared, read without decrypting.*
- *`.github/rulesets/`: `ruleset-guarantees`, before the push. `main-checks`
  stays active on the default branch, has no bypass actors, blocks deletion and
  non-fast-forward pushes, and requires both nixbot checks from the same App.*
- *`hosts/NAME/`: `boot-rollback`, before the push. NAME's enabled boot loader
  keeps at least three generations, or all of them.*
- *`tools/luvus-deliver.nu` or `tools/den-reach.nix`: `classifier-stricter`,
  before the push. The changed classifier judges the delivery too, and every
  mitigation either asks for runs; one the installed classifier cannot run
  fails it.*
- *`hosts/`, several hosts through high- or critical-risk configuration, or an
  unknown reach: `canary-first`, after `main` moves. It waits until every
  canary (`policy.autoDeploy`, named by `tools/den-reach.nix`) has staged the
  commit and made it the boot default; a revert, or no answer by the deadline,
  fails the delivery, and no other host switches to it.*

*The ledger records each mitigation's outcome and how far the delivery got
(`stage`), and a high-risk landing sends a desktop notification for review
afterwards. Dropping a path from impermanence's persistence needs no backup:
impermanence stops bind-mounting it, but its data stays under `/persist`.*

*Changed 2026-11-21: the owner removed Jev from delivery. Code alone decides
now: high risk is a path under `secrets/`, `hosts/`, or `.github/rulesets/`, a
change to `tools/luvus-deliver.nu` or `tools/den-reach.nix` (the approval paths
live in the classifier itself, so changing them needs approval), several
deployed hosts through configuration the policy rates high or critical, or a
delivery whose reach cannot be worked out. Several hosts alone no longer stop
a delivery, and boot, storage, secrets, keys, or access outside those paths
deliver as medium. The `delivery_risk` questions left `jev/questions.nuon`; the
ledger no longer records Jev's answers. Jev stays for its other questions.
What follows is the decision as it stood from 2026-10-29.*

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
  and each file's policy risk: the highest risk `den/model/policy.nix` gives an
  aspect the file reaches.
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

Rejected: a table of path globs to risk levels next to `den/model/policy.nix`,
which was the first proposal (the author preferred Jev's judgment to rules to
maintain); a hand-kept map of aspects to hosts (Den already knows, and the map
would drift); asking Jev which hosts a change reaches (code can compute it
exactly); counting every change to several hosts as high, as `AGENTS.md` stated
the rule (niri and shell edits reach both asus and homelab, so nearly every
delivery would wait for approval); and approving by branch name (an approval
would carry over to commits merged after it).
