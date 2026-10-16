---
type: task
description: Summarize landing times from the ci traces (p50/p90 per phase, lock waits, retry waste, daily trend) in a `ci times` command and a CI dashboard panel.
stage: planned
priority: medium
created: 2026-10-16
generated:
  by: claude-code/opus-5.5
  at: 2026-10-16T21:20:00Z
---

# Show landing times over time

The traces show one landing at a time. Add a `ci times` command and a matching
panel in the CI dashboard. They should give p50 and p90 per phase, time spent
waiting for local checks, time lost to landings that started over, and the trend
by day. Read the same status records the traces come from, so the history goes
back to 2026-10-07. Use it to tell whether the FIFO landing queue in ci reduces
lock waits and retries. Motivated by
[traces of ci landings](../features/ci-traces.md).
