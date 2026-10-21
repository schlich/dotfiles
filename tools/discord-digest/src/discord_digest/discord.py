"""A read-only Discord REST client that acts as you.

It authenticates with your own user token, which makes it a self-bot.
Discord's terms forbid self-bots, and an account that runs one can be
banned. This client keeps that risk low but not zero: it only ever sends
GET requests, waits between requests, and honours every rate limit Discord
reports.
"""

import time
from dataclasses import dataclass, field
from datetime import UTC, datetime

import httpx

API = "https://discord.com/api/v10"
DISCORD_EPOCH_MS = 1_420_070_400_000

# Channel types worth reading: ordinary text channels and announcement
# channels. Voice, category, stage, and forum channels hold no messages of
# their own.
READABLE_TYPES = {0: "text", 5: "announcement"}


class DiscordError(Exception):
    pass


class Unreadable(DiscordError):
    """The channel exists but you can't read its history (403/404)."""


def snowflake_at(when: datetime) -> int:
    """The smallest snowflake ID Discord could assign at WHEN."""
    return (int(when.timestamp() * 1000) - DISCORD_EPOCH_MS) << 22


def snowflake_time(snowflake: int) -> datetime:
    return datetime.fromtimestamp(((snowflake >> 22) + DISCORD_EPOCH_MS) / 1000, tz=UTC)


@dataclass
class Guild:
    id: int
    name: str


@dataclass
class Channel:
    id: int
    guild_id: int
    name: str
    kind: str
    topic: str = ""


@dataclass
class Message:
    id: int
    channel_id: int
    author: str
    content: str
    reactions: int = 0
    reply_to: int | None = None
    attachments: list[str] = field(default_factory=list)

    @property
    def time(self) -> datetime:
        return snowflake_time(self.id)

    @classmethod
    def from_api(cls, raw: dict) -> "Message":
        author = raw.get("author") or {}
        parts = [raw.get("content") or ""]
        for embed in raw.get("embeds") or []:
            parts += [embed.get("title") or "", embed.get("description") or ""]
        snapshot = (raw.get("message_snapshots") or [{}])[0].get("message") or {}
        if snapshot.get("content"):
            parts.append(f"[forwarded] {snapshot['content']}")
        ref = raw.get("message_reference") or {}
        return cls(
            id=int(raw["id"]),
            channel_id=int(raw["channel_id"]),
            author=author.get("global_name") or author.get("username") or "?",
            content="\n".join(p for p in parts if p).strip(),
            reactions=sum(r.get("count", 0) for r in raw.get("reactions") or []),
            reply_to=int(ref["message_id"]) if ref.get("message_id") and raw.get("type") == 19 else None,
            attachments=[a.get("filename", "") for a in raw.get("attachments") or []],
        )


class DiscordClient:
    def __init__(self, token: str, pace_seconds: float = 1.2, transport: httpx.BaseTransport | None = None):
        self.http = httpx.Client(
            base_url=API,
            headers={"Authorization": token},
            timeout=30,
            transport=transport,
        )
        self.pace = pace_seconds
        self._next_at = 0.0

    def _get(self, path: str, params: dict | None = None):
        for attempt in range(6):
            delay = self._next_at - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            response = self.http.get(path, params=params)
            self._next_at = time.monotonic() + self.pace

            if response.status_code == 429:
                retry_after = float(response.json().get("retry_after", 5))
                self._next_at = time.monotonic() + retry_after + 0.5
                continue
            if response.status_code == 401:
                raise DiscordError("Discord rejected the token (401). Store a fresh one with `secretspec set DISCORD_TOKEN`.")
            if response.status_code in (403, 404):
                raise Unreadable(f"{response.status_code} on {path}")
            if response.status_code >= 500:
                self._next_at = time.monotonic() + 2**attempt
                continue
            response.raise_for_status()

            # Out of requests in this bucket: wait for it to refill rather
            # than collect a 429.
            if response.headers.get("X-RateLimit-Remaining") == "0":
                reset = float(response.headers.get("X-RateLimit-Reset-After", 1))
                self._next_at = max(self._next_at, time.monotonic() + reset)
            return response.json()
        raise DiscordError(f"gave up on {path} after repeated rate limits or server errors")

    def me(self) -> str:
        user = self._get("/users/@me")
        return user.get("global_name") or user["username"]

    def guilds(self) -> list[Guild]:
        return [Guild(int(g["id"]), g["name"]) for g in self._get("/users/@me/guilds")]

    def channels(self, guild_id: int) -> list[Channel]:
        return [
            Channel(int(c["id"]), guild_id, c["name"], READABLE_TYPES[c["type"]], c.get("topic") or "")
            for c in self._get(f"/guilds/{guild_id}/channels")
            if c.get("type") in READABLE_TYPES
        ]

    def messages_after(self, channel_id: int, after: int, limit: int) -> list[Message]:
        """Messages newer than snowflake AFTER, oldest first, at most LIMIT.

        Pages backwards from the newest message, so a channel that saw more
        than LIMIT messages reports its newest LIMIT and the older surplus
        is skipped rather than read on a later run."""
        collected: list[Message] = []
        params: dict = {"limit": 100}
        while len(collected) < limit:
            page = self._get(f"/channels/{channel_id}/messages", params)
            messages = [Message.from_api(m) for m in page]
            collected += [m for m in messages if m.id > after]
            if len(page) < 100 or min(m.id for m in messages) <= after:
                break
            params["before"] = min(m.id for m in messages)
        return sorted(collected, key=lambda m: m.id)[-limit:]
