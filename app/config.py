import os
from dataclasses import dataclass
from datetime import datetime, timezone


def parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class Settings:
    database_url: str
    indexer_database_url: str
    start_at: datetime
    poll_interval_seconds: float
    batch_size: int
    replay_blocks: int

    @classmethod
    def from_env(cls) -> "Settings":
        database_url = os.getenv("DATABASE_URL", "")
        indexer_database_url = os.getenv("INDEXER_DATABASE_URL", "")
        if not database_url:
            raise ValueError("DATABASE_URL is required")
        if not indexer_database_url:
            raise ValueError("INDEXER_DATABASE_URL is required")

        batch_size = int(os.getenv("BATCH_SIZE", "1000"))
        poll_interval = float(os.getenv("POLL_INTERVAL_SECONDS", "5"))
        replay_blocks = int(os.getenv("REPLAY_BLOCKS", "20"))
        if batch_size < 1:
            raise ValueError("BATCH_SIZE must be greater than zero")
        if poll_interval <= 0:
            raise ValueError("POLL_INTERVAL_SECONDS must be greater than zero")
        if replay_blocks < 0:
            raise ValueError("REPLAY_BLOCKS cannot be negative")

        return cls(
            database_url=database_url,
            indexer_database_url=indexer_database_url,
            start_at=parse_datetime(
                os.getenv("START_AT", "2024-11-17T00:00:00Z")
            ),
            poll_interval_seconds=poll_interval,
            batch_size=batch_size,
            replay_blocks=replay_blocks,
        )
