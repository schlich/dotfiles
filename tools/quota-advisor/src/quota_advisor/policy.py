from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any


@dataclass(frozen=True)
class Window:
    name: str
    remaining: float | None
    resets_at: datetime
    observed_at: datetime
    duration: timedelta
    source: str = "manual"

    def assess(
        self, now: datetime, reserve: float, stale_hours: float
    ) -> dict[str, Any]:
        if (
            now.tzinfo is None
            or self.resets_at.tzinfo is None
            or self.observed_at.tzinfo is None
        ):
            raise ValueError("timestamps must include a timezone")
        if self.duration.total_seconds() <= 0:
            raise ValueError("window duration must be positive")
        if self.remaining is not None and not 0 <= self.remaining <= 1:
            raise ValueError("remaining must be between 0 and 1")
        freshness = (now - self.observed_at).total_seconds() / 3600
        status = "ok"
        if freshness < 0:
            status = "future_observation"
        elif now >= self.resets_at:
            status = "reset_due"
        elif freshness > stale_hours:
            status = "stale"
        elif self.remaining is None:
            status = "unknown"
        elif self.remaining == 0:
            status = "exhausted"
        time_left = max(0.0, min(1.0, (self.resets_at - now) / self.duration))
        pace_margin = (
            None
            if status not in ("ok", "exhausted")
            else round(self.remaining - reserve - time_left, 4)
        )
        return {
            "window": self.name,
            "remaining": self.remaining,
            "time_fraction_left": round(time_left, 4),
            "pace_margin": pace_margin,
            "status": status,
            "resets_at": self.resets_at.isoformat(),
            "observed_at": self.observed_at.isoformat(),
            "source": self.source,
        }


def recommend(data: dict[str, Any], now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    policy = data.get("policy", {})
    reserve = float(policy.get("weekly_reserve", 0.10))
    stale_hours = float(policy.get("stale_hours", 6))
    if not 0 <= reserve < 1 or stale_hours <= 0:
        raise ValueError(
            "weekly_reserve must be in [0,1), stale_hours must be positive"
        )
    task = data.get("task", {})
    difficulty = task.get("difficulty", "medium")
    error_cost = task.get("error_cost", "medium")
    if difficulty not in ("low", "medium", "high") or error_cost not in (
        "low",
        "medium",
        "high",
    ):
        raise ValueError("difficulty and error_cost must be low, medium, or high")
    privacy = task.get("privacy", "normal")
    if privacy not in ("normal", "sensitive"):
        raise ValueError("privacy must be normal or sensitive")
    prefer = task.get("prefer")
    if prefer not in (None, "codex", "claude"):
        raise ValueError("prefer must be codex or claude")
    allowed = task.get("allowed", ["codex", "claude"])
    if not isinstance(allowed, list) or any(
        x not in ("codex", "claude") for x in allowed
    ):
        raise ValueError("allowed must list codex and/or claude")
    options = {}
    for name in ("codex", "claude"):
        if name not in allowed:
            continue
        raw = data.get("subscriptions", {}).get(name, {})
        windows = []
        for label, hours in (("five_hour", 5), ("weekly", 168)):
            item = raw.get(label)
            if item is None:
                windows.append(
                    {"window": label, "status": "unknown", "pace_margin": None}
                )
                continue
            windows.append(
                Window(
                    label,
                    item.get("remaining"),
                    datetime.fromisoformat(item["resets_at"]),
                    datetime.fromisoformat(item["observed_at"]),
                    timedelta(hours=hours),
                    item.get("source", "manual"),
                ).assess(now, reserve if label == "weekly" else 0, stale_hours)
            )
        margins = [w["pace_margin"] for w in windows if w["pace_margin"] is not None]
        statuses = [w["status"] for w in windows]
        state = (
            "unavailable"
            if "exhausted" in statuses
            else (
                "uncertain"
                if any(s != "ok" for s in statuses)
                else (
                    "ahead_of_spend_pace" if min(margins) >= 0 else "behind_spend_pace"
                )
            )
        )
        options[name] = {
            "state": state,
            "tightest_margin": min(margins) if margins else None,
            "windows": windows,
        }
    eligible = [n for n, v in options.items() if v["state"] != "unavailable"]
    if privacy == "sensitive":
        # Both subscription products may be used, but never suggest a paid third-party API.
        pass
    if prefer in eligible:
        choice = prefer
        reason = "Explicit task preference takes priority."
    else:
        known = [n for n in eligible if options[n]["state"] != "uncertain"]
        choice = (
            max(known, key=lambda n: options[n]["tightest_margin"]) if known else None
        )
        reason = (
            "Selected the subscription with the largest margin at its tightest window."
            if choice
            else "No reliable subscription recommendation: balances are missing, stale, or exhausted."
        )
    if prefer and choice != prefer:
        choice = None
        reason = "Preferred tool is exhausted or disallowed; no silent substitution."
    high_stakes = difficulty == "high" or error_cost == "high"
    effort = "high" if high_stakes else "medium" if difficulty == "medium" else "low"
    if choice and options[choice]["state"] == "behind_spend_pace" and not high_stakes:
        effort = "low"
        reason += " Routine work uses lower effort while allowance is behind pace."
    return {
        "as_of": now.isoformat(),
        "recommendation": {
            "tool": choice,
            "reasoning_effort": effort,
            "reason": reason,
            "review_required": choice is None or high_stakes,
        },
        "options": options,
        "note": "Remaining values are allowance fractions, not token balances; effort names are advisory.",
    }
