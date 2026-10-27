import json
from datetime import UTC, datetime
from types import SimpleNamespace

import httpx

from discord_digest import cli
from discord_digest.config import ChannelFilter, load
from discord_digest.dashboard import render
from discord_digest.discord import Channel, DiscordClient, Guild, Message, snowflake_at, snowflake_time
from discord_digest.store import Store
from discord_digest.triage import Finding, Triage, Triager, chunk, format_message


def raw_message(id: int, content: str = "hi", **extra) -> dict:
    return {"id": str(id), "channel_id": "10", "author": {"username": "ann"}, "content": content, **extra}


def test_snowflake_round_trip():
    when = datetime(2026, 10, 20, 12, 0, tzinfo=UTC)
    assert snowflake_time(snowflake_at(when)) == when


def test_channel_filter_matches_ids_names_and_qualified_names():
    f = ChannelFilter(exclude_channels=["#memes", "Nix/#offtopic", "42"])
    assert not f.wants_channel(1, "memes", "Anything")
    assert not f.wants_channel(2, "offtopic", "nix")
    assert f.wants_channel(3, "offtopic", "Other")
    assert not f.wants_channel(42, "whatever", "Other")
    assert ChannelFilter(include_guilds=["NixOS"]).wants_guild(9, "nixos")
    assert not ChannelFilter(include_guilds=["NixOS"]).wants_guild(9, "Rust")


def test_config_resolves_paths_against_its_file(tmp_path):
    (tmp_path / "config.toml").write_text('data_dir = "state"\nmin_score = 6\n[channels]\nexclude_guilds = ["x"]\n')
    cfg = load(tmp_path / "config.toml")
    assert cfg.data_dir == tmp_path / "state"
    assert cfg.interests_file == tmp_path / "interests.md"
    assert cfg.min_score == 6 and cfg.channels.exclude_guilds == ["x"]


def test_messages_after_pages_backwards_and_keeps_only_newer(monkeypatch):
    monkeypatch.setattr("time.sleep", lambda s: None)
    # Newest-first pages, as Discord returns them: 300..201, then 200..101.
    pages = {None: [raw_message(i) for i in range(300, 200, -1)], "201": [raw_message(i) for i in range(200, 100, -1)]}
    seen = []

    def handler(request: httpx.Request):
        before = request.url.params.get("before")
        seen.append(before)
        return httpx.Response(200, json=pages[before])

    client = DiscordClient("t", pace_seconds=0, transport=httpx.MockTransport(handler))
    got = client.messages_after(10, after=150, limit=1000)
    assert [m.id for m in got] == list(range(151, 301))
    assert seen == [None, "201"]


def test_messages_after_caps_to_newest(monkeypatch):
    monkeypatch.setattr("time.sleep", lambda s: None)
    page = [raw_message(i) for i in range(300, 200, -1)]
    client = DiscordClient("t", pace_seconds=0, transport=httpx.MockTransport(lambda r: httpx.Response(200, json=page)))
    got = client.messages_after(10, after=0, limit=50)
    assert [m.id for m in got] == list(range(251, 301))


def test_rate_limit_is_retried(monkeypatch):
    sleeps = []
    monkeypatch.setattr("time.sleep", sleeps.append)
    responses = iter([httpx.Response(429, json={"retry_after": 2}), httpx.Response(200, json={"username": "ann"})])
    client = DiscordClient("t", pace_seconds=0, transport=httpx.MockTransport(lambda r: next(responses)))
    assert client.me() == "ann"
    assert sleeps and sleeps[0] >= 2


def test_message_from_api_collects_embeds_reactions_and_replies():
    m = Message.from_api(raw_message(
        5, "see this", type=19, message_reference={"message_id": "4"},
        embeds=[{"title": "v2.0 released"}], reactions=[{"count": 3}, {"count": 2}],
        attachments=[{"filename": "log.txt"}],
    ))
    assert m.content == "see this\nv2.0 released"
    assert m.reactions == 5 and m.reply_to == 4 and m.attachments == ["log.txt"]
    assert "5 reactions" in format_message(m) and "reply to 4" in format_message(m)


def test_chunk_splits_on_size():
    assert chunk(["a" * 10] * 5, limit=25) == [["a" * 10] * 2] * 2 + [["a" * 10]]


class FakeMessages:
    def __init__(self, triage: Triage):
        self.triage = triage
        self.calls = []

    def parse(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(stop_reason="end_turn", parsed_output=self.triage)


def test_triage_drops_invented_message_ids():
    finding = lambda ids: Finding(title="t", summary="s", category="release", score=14, why="w", message_ids=ids)
    fake = FakeMessages(Triage(findings=[finding(["1", "999"]), finding(["888"])]))
    triager = Triager("Nix", "m", "m", client=SimpleNamespace(messages=fake))
    msgs = [Message.from_api(raw_message(1, "nix 3 is out"))]
    out = triager.triage("Nix", Channel(10, 1, "announcements", "announcement"), msgs)
    assert len(out) == 1
    assert out[0]["message_ids"] == ["1"] and out[0]["score"] == 10
    assert "Nix" in fake.calls[0]["system"][0]["text"]
    assert "[1]" in fake.calls[0]["messages"][0]["content"]


def test_store_and_dashboard_round_trip(tmp_path):
    store = Store(tmp_path / "db.sqlite")
    store.upsert_guild(Guild(1, "Nix"))
    store.upsert_channel(Channel(10, 1, "announcements", "announcement"))
    run = store.start_run()
    store.record_channel(run, 10, 500, [{
        "title": "</script><b>x</b>", "summary": "s", "category": "release", "score": 9,
        "why": "w", "message_ids": ["500"], "first_message_at": datetime.now(UTC).isoformat(),
    }])
    store.finish_run(run, "- **big** news", {"channels": 1, "messages": 3})
    assert store.cursor(10) == 500

    out = render(store.recent_runs(30), store.recent_findings(30), 4, tmp_path / "site" / "index.html")
    html = out.read_text()
    assert "</script><b>" not in html
    payload = html.split('type="application/json">')[1].split("</script>")[0]
    data = json.loads(payload)
    assert data["findings"][0]["title"] == "</script><b>x</b>"
    assert data["runs"][0]["overview"] == "- **big** news"


def test_unreadable_channels_are_skipped_then_retried(tmp_path):
    store = Store(tmp_path / "db.sqlite")
    store.upsert_channel(Channel(10, 1, "secret", "text"))
    store.mark_unreadable(10)
    assert not store.readable(10)
    store.db.execute("update channels set unreadable_since = '2000-01-01T00:00:00+00:00'")
    assert store.readable(10)


def test_cli_requires_token(monkeypatch, tmp_path):
    monkeypatch.delenv("DISCORD_TOKEN", raising=False)
    monkeypatch.chdir(tmp_path)
    try:
        cli.main(["check"])
    except SystemExit as e:
        assert "DISCORD_TOKEN" in str(e)
    else:
        raise AssertionError("expected exit")
