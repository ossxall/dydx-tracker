import asyncio
import csv
import io
import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Query
from fastapi.responses import StreamingResponse

from app.config import Settings, parse_datetime
from app.db import connect_db, get_sync_state, initialize_database
from app.replicator import run_forever

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
settings = Settings.from_env()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await asyncio.to_thread(initialize_database, settings.database_url)
    stop_event = asyncio.Event()
    worker = asyncio.create_task(
        asyncio.to_thread(run_forever, settings, stop_event.is_set)
    )
    try:
        yield
    finally:
        stop_event.set()
        await worker


app = FastAPI(title="dYdX BTC-USD fills tracker", lifespan=lifespan)

FILL_COLUMNS = (
    "source_fill_id",
    "wallet",
    "subaccount_number",
    "market",
    "side",
    "liquidity",
    "fill_type",
    "price",
    "size",
    "fee",
    "created_at",
    "created_at_height",
    "event_id",
    "transaction_hash",
    "source_clob_pair_id",
    "source_order_id",
)


def make_filters(
    wallet: str | None,
    start_at: str | None,
    end_at: str | None,
) -> tuple[str, list]:
    clauses: list[str] = []
    params: list = []
    if wallet:
        clauses.append("wallet = %s")
        params.append(wallet)
    if start_at:
        clauses.append("created_at >= %s")
        params.append(parse_datetime(start_at))
    if end_at:
        clauses.append("created_at <= %s")
        params.append(parse_datetime(end_at))
    return (" WHERE " + " AND ".join(clauses) if clauses else ""), params


@app.get("/healthz")
def health() -> dict:
    state = get_sync_state(settings.database_url)
    return {
        "status": "ok",
        "last_height": state["last_height"],
        "updated_at": state["updated_at"],
    }


@app.get("/fills")
def list_fills(
    wallet: str | None = None,
    start_at: str | None = None,
    end_at: str | None = None,
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> dict:
    where, params = make_filters(wallet, start_at, end_at)
    with connect_db(settings.database_url) as connection:
        total = connection.execute(
            "SELECT count(*) AS total FROM btc_usd_fills" + where,
            params,
        ).fetchone()["total"]
        rows = connection.execute(
            "SELECT " + ", ".join(FILL_COLUMNS) + " FROM btc_usd_fills"
            + where
            + " ORDER BY created_at_height DESC, event_id, source_fill_id"
            + " LIMIT %s OFFSET %s",
            [*params, limit, offset],
        ).fetchall()
    return {"total": total, "limit": limit, "offset": offset, "fills": rows}


@app.get("/fills.csv")
def export_fills_csv(
    wallet: str | None = None,
    start_at: str | None = None,
    end_at: str | None = None,
) -> StreamingResponse:
    where, params = make_filters(wallet, start_at, end_at)

    def stream():
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(FILL_COLUMNS)
        yield buffer.getvalue()
        buffer.seek(0)
        buffer.truncate(0)

        with connect_db(settings.database_url) as connection:
            with connection.cursor(name="btc_usd_fills_export") as cursor:
                cursor.itersize = 1000
                cursor.execute(
                    "SELECT " + ", ".join(FILL_COLUMNS)
                    + " FROM btc_usd_fills" + where
                    + " ORDER BY created_at_height, event_id, source_fill_id",
                    params,
                )
                while rows := cursor.fetchmany(1000):
                    writer.writerows(
                        [row[column] for column in FILL_COLUMNS] for row in rows
                    )
                    yield buffer.getvalue()
                    buffer.seek(0)
                    buffer.truncate(0)

    return StreamingResponse(
        stream(),
        media_type="text/csv",
        headers={"Content-Disposition": 'attachment; filename="btc-usd-fills.csv"'},
    )
