from psycopg import Connection, connect
from psycopg.rows import dict_row


SCHEMA = (
    """
    CREATE TABLE IF NOT EXISTS btc_usd_fills (
        source_fill_id UUID PRIMARY KEY,
        wallet TEXT NOT NULL,
        subaccount_number INTEGER NOT NULL,
        market TEXT NOT NULL,
        side TEXT NOT NULL,
        liquidity TEXT NOT NULL,
        fill_type TEXT NOT NULL,
        price NUMERIC NOT NULL,
        size NUMERIC NOT NULL,
        fee NUMERIC NOT NULL,
        created_at TIMESTAMPTZ NOT NULL,
        created_at_height BIGINT NOT NULL,
        event_id TEXT NOT NULL,
        transaction_hash TEXT NOT NULL,
        source_clob_pair_id BIGINT NOT NULL,
        source_order_id UUID,
        synced_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS btc_usd_fills_height_event_idx
    ON btc_usd_fills (created_at_height, event_id)
    """,
    """
    CREATE INDEX IF NOT EXISTS btc_usd_fills_created_at_idx
    ON btc_usd_fills (created_at DESC)
    """,
    """
    CREATE INDEX IF NOT EXISTS btc_usd_fills_wallet_idx
    ON btc_usd_fills (wallet, created_at DESC)
    """,
    """
    CREATE TABLE IF NOT EXISTS sync_state (
        id SMALLINT PRIMARY KEY CHECK (id = 1),
        last_height BIGINT NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    INSERT INTO sync_state (id, last_height)
    VALUES (1, 0)
    ON CONFLICT (id) DO NOTHING
    """,
)


def connect_db(database_url: str) -> Connection:
    return connect(database_url, row_factory=dict_row)


def initialize_database(database_url: str) -> None:
    with connect_db(database_url) as connection:
        for statement in SCHEMA:
            connection.execute(statement)


def get_sync_state(database_url: str) -> dict:
    with connect_db(database_url) as connection:
        row = connection.execute(
            "SELECT last_height, updated_at FROM sync_state WHERE id = 1"
        ).fetchone()
        return row or {"last_height": 0, "updated_at": None}
