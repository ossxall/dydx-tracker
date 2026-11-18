import logging
import time
from datetime import datetime
from typing import Any

from psycopg import Connection

from app.config import Settings
from app.db import connect_db

logger = logging.getLogger(__name__)

SOURCE_SQL = """
    SELECT
        f."id" AS source_fill_id,
        s."address" AS wallet,
        s."subaccountNumber" AS subaccount_number,
        pm."ticker" AS market,
        f."side" AS side,
        f."liquidity" AS liquidity,
        f."type" AS fill_type,
        f."price"::text AS price,
        f."size"::text AS size,
        COALESCE(f."fee"::text, '0') AS fee,
        f."createdAt" AS created_at,
        f."createdAtHeight" AS created_at_height,
        encode(f."eventId", 'hex') AS event_id,
        f."transactionHash" AS transaction_hash,
        f."clobPairId" AS source_clob_pair_id,
        f."orderId" AS source_order_id
    FROM "fills" AS f
    JOIN "subaccounts" AS s ON s."id" = f."subaccountId"
    JOIN "perpetual_markets" AS pm ON pm."clobPairId" = f."clobPairId"
    WHERE pm."ticker" = 'BTC-USD'
      AND f."createdAt" >= %s
      AND f."createdAtHeight" > %s
      AND f."createdAtHeight" <= %s
    ORDER BY f."createdAtHeight", f."id"
"""

UPSERT_SQL = """
    INSERT INTO btc_usd_fills (
        source_fill_id, wallet, subaccount_number, market, side, liquidity,
        fill_type, price, size, fee, created_at, created_at_height, event_id,
        transaction_hash, source_clob_pair_id, source_order_id, synced_at
    ) VALUES (
        %(source_fill_id)s, %(wallet)s, %(subaccount_number)s, %(market)s,
        %(side)s, %(liquidity)s, %(fill_type)s, %(price)s, %(size)s,
        %(fee)s, %(created_at)s, %(created_at_height)s, %(event_id)s,
        %(transaction_hash)s, %(source_clob_pair_id)s, %(source_order_id)s,
        now()
    )
    ON CONFLICT (source_fill_id) DO UPDATE SET
        wallet = EXCLUDED.wallet,
        subaccount_number = EXCLUDED.subaccount_number,
        market = EXCLUDED.market,
        side = EXCLUDED.side,
        liquidity = EXCLUDED.liquidity,
        fill_type = EXCLUDED.fill_type,
        price = EXCLUDED.price,
        size = EXCLUDED.size,
        fee = EXCLUDED.fee,
        created_at = EXCLUDED.created_at,
        created_at_height = EXCLUDED.created_at_height,
        event_id = EXCLUDED.event_id,
        transaction_hash = EXCLUDED.transaction_hash,
        source_clob_pair_id = EXCLUDED.source_clob_pair_id,
        source_order_id = EXCLUDED.source_order_id,
        synced_at = now()
"""


def get_source_height(source_url: str) -> int:
    with connect_db(source_url) as source:
        row = source.execute(
            'SELECT COALESCE(MAX("blockHeight"), 0) AS height FROM "blocks"'
        ).fetchone()
    return int(row["height"])


def get_last_height(target: Connection) -> int:
    row = target.execute(
        "SELECT last_height FROM sync_state WHERE id = 1"
    ).fetchone()
    return int(row["last_height"]) if row else 0


def replicate_once(settings: Settings) -> tuple[int, int]:
    """Copy fills up to the latest block persisted by the official Indexer."""
    indexed_height = get_source_height(settings.indexer_database_url)
    total = 0
    with connect_db(settings.database_url) as target:
        last_height = get_last_height(target)
        if indexed_height < last_height:
            return 0, last_height
        # End the transaction opened by the state read. Each batch below is
        # then committed independently so a large backfill does not hold one
        # long-running target transaction.
        target.commit()

        # Re-read a small finalized window to tolerate delayed Indexer writes.
        from_height = max(0, last_height - settings.replay_blocks)
        with connect_db(settings.indexer_database_url) as source:
            with source.cursor(name="btc_usd_fills_backfill") as cursor:
                cursor.itersize = settings.batch_size
                cursor.execute(
                    SOURCE_SQL,
                    (settings.start_at, from_height, indexed_height),
                )
                while batch := cursor.fetchmany(settings.batch_size):
                    with target.transaction():
                        target.executemany(UPSERT_SQL, batch)
                    total += len(batch)

        with target.transaction():
            target.execute(
                """
                UPDATE sync_state
                SET last_height = %s, updated_at = now()
                WHERE id = 1
                """,
                (indexed_height,),
            )

    return total, indexed_height


def run_forever(settings: Settings, should_stop: Any) -> None:
    while not should_stop():
        try:
            rows, height = replicate_once(settings)
            if rows:
                logger.info("Replicated %s BTC-USD fills through height %s", rows, height)
        except Exception:
            logger.exception("Indexer sync failed; will retry")
        time.sleep(settings.poll_interval_seconds)
