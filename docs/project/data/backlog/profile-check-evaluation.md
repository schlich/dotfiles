---
type: task
description: Rank the flake checks by evaluation time and memory, with flamegraphs, to decide whether local clearance can evaluate them in parallel.
stage: done
priority: high
created: 2026-10-16
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T22:40:00Z
completed: 2026-10-16
---

# Profile flake-check evaluation

Local clearance spends most of its time evaluating the 20 flake checks, not
building them. ci runs `nix-fast-build --eval-workers 1`, so the checks are
evaluated one at a time. nix-fast-build only reports build events, so nothing
shows which checks are slow to evaluate.

Add an on-demand command that evaluates each check separately with Nix 2.34's
`eval-profiler = flamegraph` and `NIX_SHOW_STATS`. It should produce a ranking
by evaluation time and memory, plus a flamegraph per check. Use the result to
decide whether `--eval-workers 2` fits under the 9 GiB `MemoryMax` of the local
checks unit. See [traces of ci landings](../features/ci-traces.md) for the
measurements that motivated this.

## Result

`nix-profile-checks` (also `nix-suite profile-checks`, source
`tools/profile-checks.nu`) evaluates each check's drvPath in its own `nix eval`,
in a user unit with the local checks unit's memory limits, and writes
`ranking.md`, `ranking.json` and a flamegraph per check under
`~/.cache/nix-profile-checks/`.
`nix-profile-checks workers N --max-memory-size M` evaluates all checks with
nix-eval-jobs as clearance does and reports the unit's memory peak. It is a
dotfiles tool rather than a ci command because it is run by hand, needs none of
ci's landing state, and works on any flake.

Measured on asus on 2026-10-16, each check alone (the profiler adds 10-15%): 257
s in total. colmena-hive-homelab 57 s and 3.1 GiB, desktop-primary-evaluation 51
s and 1.7 GiB, colmena-hive-asus 50 s and 2.5 GiB, home-manager-nixos 41 s and
1.2 GiB; den-host-asus-headless 12 s; the other 15 checks take 1-7 s and at most
0.5 GiB each. A fresh evaluator costs about 1 s and 130 MiB.

nix-eval-jobs 2.35 treats `--max-memory-size` as a shared budget of workers
times that size. Past it, it kills the largest worker mid-check and retries the
check alone; a check that exceeds the budget alone fails.

| Workers x MiB       | Wall    | CPU   | Unit peak            | Outcome       |
| ------------------- | ------- | ----- | -------------------- | ------------- |
| 1 x 6144 (ci today) | 178 s   | 134 s | 6.0 GiB + 2 GiB swap | 1 retry       |
| 1 x 4096            | 224 s   | 162 s | 4.0 GiB + 2 GiB swap | 2 retries     |
| 1 x 2048            |         |       | 2.1 GiB              | 3 checks fail |
| 2 x 3072            | 237 s   | 241 s | 5.9 GiB + 2 GiB swap | 1 retry       |
| 2 x 6144            | > 700 s |       | pinned at MemoryHigh | stopped       |

Decision: keep one eval worker. A single worker shares the evaluation of
nixpkgs, Den and the hosts across checks (134 s of CPU against 257 s evaluated
separately); two workers lose that sharing, so at the same 6 GiB they are
slower, and at 2 x 6144 the budget exceeds the unit and thrashes. Lowering ci's
`--eval-max-memory-size` to 4096 cuts clearance memory by 2 GiB for about 46 s
more evaluation; below about 3.2 GiB the largest checks fail. Every run used the
unit's full 2 GiB of swap, so asus is short of memory during clearance
regardless of the setting.

The flamegraphs show where to cut check cost instead. colmena-hive-NAME
evaluates its host twice (colmena and Den) to compare drvPaths, which adds about
10 s and 0.9 GiB per host over one evaluation. A quarter of colmena-hive-homelab
was the spindle's VM image, which instantiated a second nixpkgs (retired
2026-10-19). asus's Home Manager generation is evaluated by colmena-hive-asus,
desktop-primary-evaluation and home-manager-nixos.
