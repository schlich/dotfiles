"""SQLite state: each channel's read cursor, findings, and run history.

Message text is kept only as long as a finding needs its context; the cursor
alone decides what the next run reads."""

import json
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .discord import Channel, Guild

SCHEMA = """
create table if not exists guilds (
    id integer primary key,
    name text not null
);
create table if not exists channels (
    id integer primary key,
    guild_id integer not null,
    name text not null,
    kind text not null,
    topic text not null default '',
    cursor integer,
    unreadable_since text
);
create table if not exists runs (
    id integer primary key autoincrement,
    started text not null,
    finished text,
    overview text,
    stats text
);
create table if not exists findings (
    id integer primary key autoincrement,
    run_id integer not null references runs(id),
    channel_id integer not null references channels(id),
    title text not null,
    summary text not null,
    category text not null,
    score integer not null,
    why text not null,
    message_ids text not null,
    first_message_at text not null
);
create index if not exists findings_by_run on findings(run_id);
"""

# A channel you can't read gets retried after this long, in case a role
# change opened it up.
UNREADABLE_RETRY = timedelta(days=7)


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def upsert_guild(self, guild: Guild) -> None:
        with self.db:
            self.db.execute(
                "insert into guilds (id, name) values (?, ?) on conflict(id) do update set name = excluded.name",
                (guild.id, guild.name),
            )

    def upsert_channel(self, channel: Channel) -> None:
        with self.db:
            self.db.execute(
                """insert into channels (id, guild_id, name, kind, topic) values (?, ?, ?, ?, ?)
                   on conflict(id) do update set name = excluded.name, kind = excluded.kind, topic = excluded.topic""",
                (channel.id, channel.guild_id, channel.name, channel.kind, channel.topic),
            )

    def cursor(self, channel_id: int) -> int | None:
        row = self.db.execute("select cursor from channels where id = ?", (channel_id,)).fetchone()
        return row["cursor"] if row else None

    def readable(self, channel_id: int) -> bool:
        row = self.db.execute("select unreadable_since from channels where id = ?", (channel_id,)).fetchone()
        if not row or not row["unreadable_since"]:
            return True
        return datetime.fromisoformat(row["unreadable_since"]) + UNREADABLE_RETRY < datetime.now(UTC)

    def mark_unreadable(self, channel_id: int) -> None:
        with self.db:
            self.db.execute("update channels set unreadable_since = ? where id = ?", (now(), channel_id))

    def start_run(self) -> int:
        with self.db:
            return self.db.execute("insert into runs (started) values (?)", (now(),)).lastrowid

    def finish_run(self, run_id: int, overview: str | None, stats: dict) -> None:
        with self.db:
            self.db.execute(
                "update runs set finished = ?, overview = ?, stats = ? where id = ?",
                (now(), overview, json.dumps(stats), run_id),
            )

    def record_channel(self, run_id: int, channel_id: int, cursor: int, findings: list[dict]) -> None:
        """Saves a channel's findings and advances its cursor in one
        transaction, so a crash between them never skips messages."""
        with self.db:
            self.db.executemany(
                """insert into findings (run_id, channel_id, title, summary, category, score, why, message_ids, first_message_at)
                   values (:run_id, :channel_id, :title, :summary, :category, :score, :why, :message_ids, :first_message_at)""",
                [{**f, "run_id": run_id, "channel_id": channel_id, "message_ids": json.dumps(f["message_ids"])} for f in findings],
            )
            self.db.execute("update channels set cursor = ?, unreadable_since = null where id = ?", (cursor, channel_id))

    def recent_findings(self, days: int) -> list[dict]:
        since = (datetime.now(UTC) - timedelta(days=days)).isoformat()
        rows = self.db.execute(
            """select f.*, c.name as channel, c.guild_id, g.name as guild, r.started as run_started
               from findings f
               join channels c on c.id = f.channel_id
               join guilds g on g.id = c.guild_id
               join runs r on r.id = f.run_id
               where f.first_message_at >= ?
               order by r.started desc, f.score desc""",
            (since,),
        ).fetchall()
        return [{**dict(r), "message_ids": json.loads(r["message_ids"])} for r in rows]

    def run_findings(self, run_id: int) -> list[dict]:
        return [f for f in self.recent_findings(days=36500) if f["run_id"] == run_id]

    def recent_runs(self, days: int) -> list[dict]:
        since = (datetime.now(UTC) - timedelta(days=days)).isoformat()
        rows = self.db.execute(
            "select * from runs where started >= ? and finished is not null order by started desc, id desc", (since,)
        ).fetchall()
        return [{**dict(r), "stats": json.loads(r["stats"] or "{}")} for r in rows]

    def channel_table(self) -> list[dict]:
        rows = self.db.execute(
            """select g.name as guild, c.name as channel, c.id, c.kind, c.cursor, c.unreadable_since
               from channels c join guilds g on g.id = c.guild_id order by g.name, c.name"""
        ).fetchall()
        return [dict(r) for r in rows]
