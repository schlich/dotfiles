"""Optional semantic task classification through OpenRouter Decisions API."""

import json
import os
from urllib.request import Request, urlopen

URL = "https://openrouter.ai/api/alpha/decisions"
MODEL = "typesafe/jev-1.13"
CRITERIA = {
    "low": "Routine, bounded task with an easy deterministic check",
    "medium": "Moderate investigation or implementation with several decisions",
    "high": "Deep or novel reasoning with substantial uncertainty",
}
ERROR_COST = {
    "low": "A wrong result is quickly noticed and cheap to correct",
    "medium": "A wrong result wastes meaningful time or requires review",
    "high": "A wrong result risks irreversible changes, sensitive data, or substantial harm",
}


def classify(description: str, api_key: str | None = None, opener=urlopen) -> dict:
    key = api_key or os.environ.get("OPENROUTER_API_KEY")
    if not key:
        raise ValueError("OPENROUTER_API_KEY is required for --jev")
    body = {
        "model": MODEL,
        "state": {"task": description},
        "questions": {
            "difficulty": {
                "type": "choice",
                "instructions": "How difficult is the task in `task`?",
                "criteria": CRITERIA,
            },
            "error_cost": {
                "type": "choice",
                "instructions": "What is the cost of an incorrect result for `task`?",
                "criteria": ERROR_COST,
            },
        },
    }
    request = Request(
        URL,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    with opener(request, timeout=15) as response:
        result = json.load(response)
    answers = result["answers"]
    labels = {}
    for field in ("difficulty", "error_cost"):
        answer = answers[field]
        label = answer["choice"]
        if answer["type"] != "choice" or label not in ("low", "medium", "high"):
            raise ValueError(f"Unexpected Jev answer for {field}")
        labels[field] = label
    return {
        "labels": labels,
        "answers": answers,
        "model": result.get("model"),
        "usage": result.get("usage"),
        "unvalidated_probabilities": True,
    }
