"""Dedicated SQLite persistence for HealthKit ingest data."""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .models import IngestBatch, NumericSample, SleepSample


@dataclass(frozen=True)
class IngestResult:
    accepted: int
    duplicates: int


@dataclass(frozen=True)
class IngestStatus:
    last_ingest_at: str | None
    last_successful_batch_at: str | None
    last_error_at: str | None
    last_error_category: str | None


_SCHEMA = """
CREATE TABLE IF NOT EXISTS healthkit_numeric_samples (
    uuid TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK(type IN ('heart_rate','hrv','steps')),
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    source_name TEXT,
    source_bundle TEXT,
    device TEXT,
    metadata_json TEXT NOT NULL,
    queued_at TEXT NOT NULL,
    received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS healthkit_sleep_samples (
    uuid TEXT PRIMARY KEY,
    stage TEXT NOT NULL,
    stage_raw TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    source_name TEXT,
    source_bundle TEXT,
    device TEXT,
    metadata_json TEXT NOT NULL,
    queued_at TEXT NOT NULL,
    received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS healthkit_ingest_status (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    last_ingest_at TEXT,
    last_successful_batch_at TEXT,
    last_error_at TEXT,
    last_error_category TEXT
);
"""


def _utc_text(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("received_at must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class HealthKitStore:
    def __init__(self, path: Path):
        self.path = Path(path)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            conn.execute(
                """
                INSERT INTO healthkit_ingest_status (
                    singleton, last_ingest_at, last_successful_batch_at, last_error_at, last_error_category
                ) VALUES (1, NULL, NULL, NULL, NULL)
                ON CONFLICT(singleton) DO NOTHING
                """
            )

    def _insert_numeric(self, conn: sqlite3.Connection, sample: NumericSample, received_at: str) -> bool:
        cursor = conn.execute(
            """
            INSERT INTO healthkit_numeric_samples (
                uuid, type, value, unit, start_at, end_at, source_name, source_bundle,
                device, metadata_json, queued_at, received_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO NOTHING
            """,
            (
                sample.uuid,
                sample.type,
                sample.value,
                sample.unit,
                sample.start_at,
                sample.end_at,
                sample.source_name,
                sample.source_bundle,
                sample.device,
                json.dumps(sample.metadata, separators=(",", ":"), sort_keys=True),
                sample.queued_at,
                received_at,
            ),
        )
        return cursor.rowcount == 1

    def _insert_sleep(self, conn: sqlite3.Connection, sample: SleepSample, received_at: str) -> bool:
        cursor = conn.execute(
            """
            INSERT INTO healthkit_sleep_samples (
                uuid, stage, stage_raw, start_at, end_at, source_name, source_bundle,
                device, metadata_json, queued_at, received_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO NOTHING
            """,
            (
                sample.uuid,
                sample.stage,
                sample.stage_raw,
                sample.start_at,
                sample.end_at,
                sample.source_name,
                sample.source_bundle,
                sample.device,
                json.dumps(sample.metadata, separators=(",", ":"), sort_keys=True),
                sample.queued_at,
                received_at,
            ),
        )
        return cursor.rowcount == 1

    def ingest(self, batch: IngestBatch, *, received_at: datetime) -> IngestResult:
        received_text = _utc_text(received_at)
        accepted = 0
        duplicates = 0
        with self._connect() as conn:
            for sample in batch.samples:
                if isinstance(sample, NumericSample):
                    inserted = self._insert_numeric(conn, sample, received_text)
                else:
                    inserted = self._insert_sleep(conn, sample, received_text)
                if inserted:
                    accepted += 1
                else:
                    duplicates += 1
            conn.execute(
                """
                UPDATE healthkit_ingest_status
                SET last_ingest_at = ?,
                    last_successful_batch_at = ?,
                    last_error_at = NULL,
                    last_error_category = NULL
                WHERE singleton = 1
                """,
                (received_text, received_text),
            )
        return IngestResult(accepted=accepted, duplicates=duplicates)

    def status(self) -> IngestStatus:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT last_ingest_at, last_successful_batch_at, last_error_at, last_error_category
                FROM healthkit_ingest_status WHERE singleton = 1
                """
            ).fetchone()
        if row is None:
            return IngestStatus(None, None, None, None)
        return IngestStatus(*row)
