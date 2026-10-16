import json
import unittest
from copy import deepcopy
from datetime import datetime
from pathlib import Path

from quota_advisor.policy import recommend

EXAMPLE = json.loads((Path(__file__).parents[1] / "example.json").read_text())
NOW = datetime.fromisoformat("2026-09-29T07:45:00-05:00")


class PolicyTest(unittest.TestCase):
    def test_switches_to_healthier_subscription(self):
        result = recommend(EXAMPLE, NOW)
        self.assertEqual(result["recommendation"]["tool"], "claude")
        self.assertLess(result["options"]["codex"]["tightest_margin"], 0)

    def test_stale_balances_do_not_create_false_certainty(self):
        result = recommend(EXAMPLE, datetime.fromisoformat("2026-09-29T15:00:00-05:00"))
        self.assertIsNone(result["recommendation"]["tool"])

    def test_exhaustion_and_preference_require_review(self):
        data = deepcopy(EXAMPLE)
        data["task"]["prefer"] = "codex"
        data["subscriptions"]["codex"]["five_hour"]["remaining"] = 0
        result = recommend(data, NOW)
        self.assertIsNone(result["recommendation"]["tool"])

    def test_high_stakes_preserves_effort(self):
        data = deepcopy(EXAMPLE)
        data["task"]["error_cost"] = "high"
        self.assertEqual(
            recommend(data, NOW)["recommendation"]["reasoning_effort"], "high"
        )

    def test_unknown_window_requires_review(self):
        data = deepcopy(EXAMPLE)
        del data["subscriptions"]["codex"]["weekly"]
        del data["subscriptions"]["claude"]["weekly"]
        self.assertIsNone(recommend(data, NOW)["recommendation"]["tool"])


if __name__ == "__main__":
    unittest.main()
