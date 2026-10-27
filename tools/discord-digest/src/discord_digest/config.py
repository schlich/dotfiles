"""Settings from config.toml. Credentials never live here: secretspec puts
DISCORD_TOKEN and ANTHROPIC_API_KEY in the environment."""

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CONFIG = Path("config.toml")


@dataclass
class ChannelFilter:
    """Which channels to read. Entries match a server or channel by ID or by
    name; a channel entry may also be written "Server/#channel"."""

    include_guilds: list[str] = field(default_factory=list)
    exclude_guilds: list[str] = field(default_factory=list)
    include_channels: list[str] = field(default_factory=list)
    exclude_channels: list[str] = field(default_factory=list)

    def wants_guild(self, guild_id: int, name: str) -> bool:
        keys = {str(guild_id), name.casefold()}
        if self.include_guilds and not keys & _fold(self.include_guilds):
            return False
        return not keys & _fold(self.exclude_guilds)

    def wants_channel(self, channel_id: int, name: str, guild_name: str) -> bool:
        keys = {str(channel_id), name.casefold(), f"#{name}".casefold(), f"{guild_name}/#{name}".casefold()}
        if self.include_channels and not keys & _fold(self.include_channels):
            return False
        return not keys & _fold(self.exclude_channels)


def _fold(entries: list[str]) -> set[str]:
    return {str(e).casefold() for e in entries}


@dataclass
class Config:
    data_dir: Path = Path("~/.local/share/discord-digest").expanduser()
    interests_file: Path = Path("interests.md")
    first_run_hours: int = 24
    max_messages_per_channel: int = 1000
    request_pace_seconds: float = 1.2
    triage_model: str = "claude-haiku-5-5"
    overview_model: str = "claude-opus-5-5"
    min_score: int = 4
    keep_days: int = 30
    channels: ChannelFilter = field(default_factory=ChannelFilter)

    @property
    def db_path(self) -> Path:
        return self.data_dir / "digest.sqlite"

    @property
    def dashboard_path(self) -> Path:
        return self.data_dir / "site" / "index.html"


def load(path: Path | None = None) -> Config:
    """Reads the config from PATH, $DISCORD_DIGEST_CONFIG, or ./config.toml.
    A missing file means every default. Relative paths in the file resolve
    against the file's own directory."""
    path = path or Path(os.environ.get("DISCORD_DIGEST_CONFIG", DEFAULT_CONFIG))
    raw = tomllib.loads(path.read_text()) if path.exists() else {}
    base = path.parent.resolve()

    channels = ChannelFilter(**raw.pop("channels", {}))
    config = Config(channels=channels, **raw)
    config.data_dir = _resolve(config.data_dir, base)
    config.interests_file = _resolve(config.interests_file, base)
    return config


def _resolve(value: Path | str, base: Path) -> Path:
    p = Path(value).expanduser()
    return p if p.is_absolute() else base / p
