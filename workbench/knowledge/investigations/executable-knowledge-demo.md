---
type: investigation
status: active
project: executable-knowledge
environment: visualization
title: Executable knowledge demo
marimo-version: 0.24.2
---

# Executable knowledge demo

This investigation is an ordinary Markdown document, a typed IWE node, and a
marimo notebook at the same time. It applies the idea of
[executable knowledge](../concepts/executable-knowledge.md) and records its
software environment as described in
[Nix closure provenance](../concepts/nix-closure-provenance.md).

```python {.marimo}
import marimo as mo
```

## Question

A detector sees unit-variance Gaussian noise, and a signal shifts that
distribution by a sensitivity `d'`. How do the hit rate and the false-alarm
rate trade off as the detection threshold moves?

```python {.marimo}
sensitivity = mo.ui.slider(0.0, 4.0, step=0.1, value=1.5, label="Sensitivity d'")
threshold = mo.ui.slider(-2.0, 4.0, step=0.1, value=0.75, label="Threshold")
mo.hstack([sensitivity, threshold])
```

```python {.marimo}
from statistics import NormalDist

import altair as alt
import polars as pl

noise = NormalDist(0.0, 1.0)
signal = NormalDist(sensitivity.value, 1.0)
hit_rate = 1.0 - signal.cdf(threshold.value)
false_alarm_rate = 1.0 - noise.cdf(threshold.value)

curve = pl.DataFrame(
    {
        "threshold": [t / 10 for t in range(-40, 61)],
    }
).with_columns(
    false_alarm=pl.col("threshold").map_elements(
        lambda t: 1.0 - noise.cdf(t), return_dtype=pl.Float64
    ),
    hit=pl.col("threshold").map_elements(
        lambda t: 1.0 - signal.cdf(t), return_dtype=pl.Float64
    ),
)
operating_point = pl.DataFrame(
    {"false_alarm": [false_alarm_rate], "hit": [hit_rate]}
)

roc = alt.Chart(curve).mark_line().encode(
    x=alt.X("false_alarm", title="False-alarm rate"),
    y=alt.Y("hit", title="Hit rate"),
) + alt.Chart(operating_point).mark_point(size=120, filled=True).encode(
    x="false_alarm", y="hit"
)
mo.vstack(
    [
        mo.md(
            f"At threshold **{threshold.value:.2f}** the hit rate is "
            f"**{hit_rate:.3f}** and the false-alarm rate is "
            f"**{false_alarm_rate:.3f}**."
        ),
        mo.ui.altair_chart(roc.properties(width=420, height=320)),
    ]
)
```

## Provenance

The cell below asks the knowledge graph about this document through the IWE
CLI and compares the declared environment with the one that is running.

```python {.marimo}
import os
import sys

import iwe_bridge

node = iwe_bridge.node_for_path(__file__)
declared = node["frontmatter"].get("environment")
running = os.environ.get("WORKBENCH_ENVIRONMENT", "unmanaged")
provenance = {
    "IWE key": node["key"],
    "declared environment": declared,
    "running environment": running,
    "matches": declared == running,
    "python": sys.version.split()[0],
    "interpreter prefix": sys.base_prefix,
    "marimo": mo.__version__,
    "included by": ", ".join(node["included_by"]) or "none",
    "references": ", ".join(node["references"]) or "none",
}
mo.ui.table(
    [{"field": key, "value": str(value)} for key, value in provenance.items()],
    selection=None,
)
```

## Interpretation

Raising the threshold lowers both rates together; only a larger `d'` moves
the whole curve toward the upper-left corner. Choosing a threshold is
therefore a decision about the relative cost of misses and false alarms, not
a way to improve the detector.
