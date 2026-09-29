# Quota Advisor

A local, explainable recommendation for choosing Codex (ChatGPT Plus) or Claude Code (Claude Pro) from manually recorded usage snapshots. It never launches an agent or changes account settings.

## Run

```sh
nix develop  # if Nix with flakes is available
python3 -m pip install -e .
quota-advisor example.json --at 2026-09-29T07:45:00-05:00
OPENROUTER_API_KEY=... quota-advisor example.json --jev
# In the dotfiles repository: nix run .#quota-advisor -- tools/quota-advisor/example.json
# Without installation: PYTHONPATH=src python3 -m quota_advisor.cli example.json
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Edit `example.json` with the percentages **remaining**, reset timestamps, and observation timestamps from each product's usage view. Enter `0.35` for 35%, in ISO 8601 with a timezone offset. Treat an unknown value as `null` or omit the window. The example is illustrative, not your account data. For a decision record, pass `--log decisions.jsonl --actual claude`; omit `--actual` if the choice has not yet been made. The log can contain task descriptions, so keep it private.

The optional `--jev` flag calls OpenRouter's [Decisions API](https://openrouter.ai/blog/tutorials/how-to-use-jev/) with `typesafe/jev-1.13` to classify task difficulty and error cost. Explicit fields in the snapshot override Jev. Only the task description is sent; subscription balances stay local. Sensitive tasks are blocked. Jev-assisted recommendations require review until its probabilities are evaluated on your tasks. This is separately billed API usage. Without the flag, the advisor is fully offline.

The two clocks for each subscription are assessed independently. A window's margin is `remaining fraction - reserved fraction - fraction of window time left`. The weekly reserve defaults to 10%; change it in `policy`. The minimum margin governs each subscription. The highest minimum margin wins when both subscriptions have fresh, complete observations. A high error cost or difficulty preserves high effort. Explicit task preference is honored, even when that means asking for review instead of silently switching. `allowed` restricts the candidate list. This is a pacing heuristic, not a prediction of exact future capacity; the five-hour period may be a rolling/session window whose start cannot be inferred precisely from the reset alone.

## Data and product boundary

- OpenAI documents a Codex usage dashboard and account settings for limits; usage depends on the model, task size and reasoning effort. ChatGPT/Codex subscription allowance is separate from API billing. See [Codex plan usage](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) and [usage dashboard](https://help.openai.com/en/articles/20001478-reviewing-work-and-codex-usage-and-using-personal-analytics-in-chatgpt-desktop).
- Anthropic documents five-hour and weekly usage progress in **Settings → Usage**. Claude and Claude Code share subscription allowance; Claude API billing is separate. See [usage best practices](https://support.claude.com/en/articles/9797557-usage-limit-best-practices), [Pro plan](https://support.claude.com/en/articles/8325606-what-is-the-pro-plan), and [Claude Code with Pro](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan).
- No supported personal-subscription balance API was established in this investigation. Manual input is the supported starting point; do not scrape private endpoints or use OpenRouter credit balances as a proxy. Subscription percentages are not token counts. An observation older than six hours, a passed reset, or a missing window prevents an automatic choice.

## Next development slice

Evaluate Jev probabilities against labeled task outcomes before using a confidence threshold. Validate an official usage integration if either provider publishes one for personal subscriptions. A UI can then graph observed margin and projected demand, with uncertainty from sparse snapshots clearly shown.

## Development status

The policy, CLI, example and focused tests run with Python's standard library; the `quota-advisor` flake check runs the tests. Jev integration is tested with a mocked response but has not been exercised against the paid API. There is no live account connection yet.
