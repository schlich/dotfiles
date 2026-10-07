---
name: token-budget-controller
description: Guide model and reasoning-effort selection under multiple token or compute budgets. Use when deciding how aggressively to spend scarce model capacity across short and long usage windows, when comparing steady pacing versus bursts, or when building dashboards/controllers for token-budget guidance.
metadata:
  short-description: Allocate model compute across rolling usage windows
---

# Token Budget Controller

Treat token budgeting as a constrained flow-and-control problem, not as a requirement to maintain a constant burn rate.

The core objective is:

> maximize useful work subject to one or more cumulative compute constraints.

## Core model

Let `r(t)` be instantaneous compute/token burn rate, `U(t)` cumulative usage, `B_i` a budget, and `T_i` its horizon.

```text
U(t) = integral r(tau) d tau
```

For a rolling window:

```text
integral from (t - T_i) to t of r(tau) d tau <= B_i
```

Crossing the average sustainable burn rate is not inherently bad. Bursts are acceptable when cumulative usage remains feasible across all active constraints.

## Never invent account limits

Do not guess plan-specific quotas, reset semantics, model multipliers, or token accounting. Use live/account data if explicitly available, exact limits supplied by the user, or clearly labeled hypothetical examples.

## Reference trajectory, not target trajectory

For a fixed window:

```text
P_i(t) = B_i * elapsed_i / T_i
S_i(t) = P_i(t) - U_i(t)
```

Treat `P_i` as an even-spend reference, not a command to force usage back to a line. For rolling windows, account for usage expiring from the window.

## Headroom and binding constraints

For every active constraint compute:

```text
headroom_i = B_i - U_i
fraction_remaining_i = headroom_i / B_i
```

Identify which constraint is most likely to bind first. Do not collapse short and long horizons into one percentage.

## Forecast before recommending

When data permits, compare:
- recent burn rate continuing,
- a bounded burst using the proposed model/effort,
- dropping to cheaper compute after the burst.

Prefer a time-to-bound or post-burst trajectory over generic warnings.

## Compute has a shadow price

Reason about the marginal value of additional compute:

```text
compute_value ~= expected task value gained / marginal budget consumed
```

As headroom shrinks, the shadow price of expensive compute rises. Favor more compute for difficult, high-value, risky, irreversible, or expensive-to-redo tasks. Favor cheaper compute for routine, reversible, easily verified work.

## Guidance modes

### Conserve
Use the cheapest capable model/effort when a binding constraint is near and task value is modest.

### Cruise
Use normal/default compute when usage is comfortably feasible and task value is ordinary.

### Burst
Deliberately exceed the even-spend burn rate for a bounded interval when adequate cumulative headroom exists and marginal task value justifies it.

Pair every burst with a forecast of which constraint it consumes and what cooldown or cheaper-compute period follows.

## Pace corridor

Prefer a corridor visualization over a single pacing line. Show:
1. cumulative actual usage,
2. the even-spend reference,
3. rolling/fixed budget ceilings,
4. a safe corridor,
5. projected trajectories for candidate models/efforts,
6. usage scheduled to expire from rolling windows.

## Decision procedure

1. Normalize all active usage constraints.
2. Compute current headroom for each.
3. Identify the likely binding constraint.
4. Estimate incremental cost of candidate model/effort choices.
5. Assess the task's marginal value of extra reasoning.
6. Forecast the post-decision trajectory.
7. Recommend the least expensive option whose expected capability is adequate.
8. Escalate to Burst when added compute has high expected value and sufficient headroom exists.
9. State assumptions and uncertainty.

## Output contract

Return:
- **Mode:** Conserve, Cruise, or Burst.
- **Binding constraint:** which horizon matters most now.
- **Headroom:** quantitative when available.
- **Recommendation:** model/effort without inventing unavailable quota details.
- **Why:** marginal value versus marginal compute.
- **Trajectory:** what happens if the proposed rate continues.
- **Fallback:** how to reduce compute if the forecast tightens.

Avoid moralizing language. Optimize useful work under constraints, not smoothness for its own sake.
