"""Dedicated SQLite persistence for HealthKit ingest data."""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .models import Deletion, IngestBatch, NumericSample, SleepSample, StepAggregate


@dataclass(frozen=True)
class IngestResult:
    accepted: int
    duplicates: int
    deleted: int
    server_time: str


@dataclass(frozen=True)
class IngestStatus:
    last_ingest_at: str | None
    last_successful_batch_at: str | None
    last_error_at: str | None
    last_error_category: str | None


@dataclass(frozen=True)
class DeviceStatus:
    device_id: str
    app_version: str | None
    queue_depth: int | None
    last_upload_at: str
    client_sent_at: str


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
    received_at TEXT NOT NULL,
    deleted_at TEXT
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
    received_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE TABLE IF NOT EXISTS healthkit_deletions (
    uuid TEXT NOT NULL,
    metric TEXT NOT NULL,
    queued_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    PRIMARY KEY(uuid, metric)
);
CREATE TABLE IF NOT EXISTS healthkit_aggregates (
    device_id TEXT NOT NULL,
    metric TEXT NOT NULL CHECK(metric = 'steps'),
    bucket_start TEXT NOT NULL,
    bucket_end TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT NOT NULL CHECK(unit = 'count'),
    computed_at TEXT NOT NULL,
    source TEXT NOT NULL,
    received_at TEXT NOT NULL,
    PRIMARY KEY(device_id, metric, bucket_start, bucket_end)
);
CREATE TABLE IF NOT EXISTS healthkit_devices (
    device_id TEXT PRIMARY KEY,
    app_version TEXT,
    queue_depth INTEGER,
    last_upload_at TEXT NOT NULL,
    client_sent_at TEXT NOT NULL
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

    @staticmethod
    def _ensure_column(conn: sqlite3.Connection, table: str, column: str, definition: str) -> None:
        columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        if column not in columns:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            self._ensure_column(conn, "healthkit_numeric_samples", "deleted_at", "TEXT")
            self._ensure_column(conn, "healthkit_sleep_samples", "deleted_at", "TEXT")
            conn.execute(
                """
                INSERT INTO healthkit_ingest_status (
                    singleton, last_ingest_at, last_successful_batch_at, last_error_at, last_error_category
                ) VALUES (1, NULL, NULL, NULL, NULL)
                ON CONFLICT(singleton) DO NOTHING
                """
            )

    @staticmethod
    def _tombstone_time(conn: sqlite3.Connection, uuid: str, metric: str) -> str | None:
        row = conn.execute(
            "SELECT received_at FROM healthkit_deletions WHERE uuid = ? AND metric = ?",
            (uuid, metric),
        ).fetchone()
        return row[0] if row else None

    def _insert_numeric(self, conn: sqlite3.Connection, sample: NumericSample, received_at: str) -> bool:
        deleted_at = self._tombstone_time(conn, sample.uuid, sample.type)
        cursor = conn.execute(
            """
            INSERT INTO healthkit_numeric_samples (
                uuid, type, value, unit, start_at, end_at, source_name, source_bundle,
                device, metadata_json, queued_at, received_at, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO NOTHING
            """,
            (
                sample.uuid, sample.type, sample.value, sample.unit, sample.start_at, sample.end_at,
                sample.source_name, sample.source_bundle, sample.device,
                json.dumps(sample.metadata, separators=(",", ":"), sort_keys=True),
                sample.queued_at, received_at, deleted_at,
            ),
        )
        return cursor.rowcount == 1

    def _insert_sleep(self, conn: sqlite3.Connection, sample: SleepSample, received_at: str) -> bool:
        deleted_at = self._tombstone_time(conn, sample.uuid, "sleep")
        cursor = conn.execute(
            """
            INSERT INTO healthkit_sleep_samples (
                uuid, stage, stage_raw, start_at, end_at, source_name, source_bundle,
                device, metadata_json, queued_at, received_at, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO NOTHING
            """,
            (
                sample.uuid, sample.stage, str(sample.stage_raw), sample.start_at, sample.end_at,
                sample.source_name, sample.source_bundle, sample.device,
                json.dumps(sample.metadata, separators=(",", ":"), sort_keys=True),
                sample.queued_at, received_at, deleted_at,
            ),
        )
        return cursor.rowcount == 1

    @staticmethod
    def _apply_deletion(conn: sqlite3.Connection, deletion: Deletion, received_at: str) -> bool:
        inserted = conn.execute(
            """
            INSERT INTO healthkit_deletions(uuid, metric, queued_at, received_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(uuid, metric) DO NOTHING
            """,
            (deletion.uuid, deletion.metric, deletion.queued_at, received_at),
        ).rowcount == 1
        if not inserted:
            return False
        if deletion.metric == "sleep":
            conn.execute(
                "UPDATE healthkit_sleep_samples SET deleted_at = COALESCE(deleted_at, ?) WHERE uuid = ?",
                (received_at, deletion.uuid),
            )
        else:
            conn.execute(
                """
                UPDATE healthkit_numeric_samples
                SET deleted_at = COALESCE(deleted_at, ?)
                WHERE uuid = ? AND type = ?
                """,
                (received_at, deletion.uuid, deletion.metric),
            )
        return True

    @staticmethod
    def _upsert_aggregate(conn: sqlite3.Connection, device_id: str, aggregate: StepAggregate, received_at: str) -> None:
        conn.execute(
            """
            INSERT INTO healthkit_aggregates (
                device_id, metric, bucket_start, bucket_end, value, unit, computed_at, source, received_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_id, metric, bucket_start, bucket_end) DO UPDATE SET
                value = excluded.value,
                unit = excluded.unit,
                computed_at = excluded.computed_at,
                source = excluded.source,
                received_at = excluded.received_at
            """,
            (
                device_id, aggregate.metric, aggregate.bucket_start, aggregate.bucket_end,
                aggregate.value, aggregate.unit, aggregate.computed_at, aggregate.source, received_at,
            ),
        )

    @staticmethod
    def _upsert_device(conn: sqlite3.Connection, batch: IngestBatch, received_at: str) -> None:
        conn.execute(
            """
            INSERT INTO healthkit_devices(device_id, app_version, queue_depth, last_upload_at, client_sent_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                app_version = excluded.app_version,
                queue_depth = excluded.queue_depth,
                last_upload_at = excluded.last_upload_at,
                client_sent_at = excluded.client_sent_at
            """,
            (batch.device_id, batch.app_version, batch.queue_depth, received_at, batch.sent_at),
        )

    def ingest(self, batch: IngestBatch, *, received_at: datetime) -> IngestResult:
        received_text = _utc_text(received_at)
        accepted = 0
        duplicates = 0
        deleted = 0
        with self._connect() as conn:
            for sample in batch.samples:
                inserted = self._insert_numeric(conn, sample, received_text) if isinstance(sample, NumericSample) else self._insert_sleep(conn, sample, received_text)
                if inserted:
                    accepted += 1
                else:
                    duplicates += 1
            for deletion in batch.deletions:
                if self._apply_deletion(conn, deletion, received_text):
                    deleted += 1
            for aggregate in batch.aggregates:
                self._upsert_aggregate(conn, batch.device_id, aggregate, received_text)
            self._upsert_device(conn, batch, received_text)
            conn.execute(
                """
                UPDATE healthkit_ingest_status
                SET last_ingest_at = ?, last_successful_batch_at = ?,
                    last_error_at = NULL, last_error_category = NULL
                WHERE singleton = 1
                """,
                (received_text, received_text),
            )
        return IngestResult(accepted=accepted, duplicates=duplicates, deleted=deleted, server_time=received_text)

    def record_error(self, category: str, *, occurred_at: datetime) -> None:
        occurred_text = _utc_text(occurred_at)
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE healthkit_ingest_status
                SET last_error_at = ?, last_error_category = ?
                WHERE singleton = 1
                """,
                (occurred_text, category),
            )

    def status(self) -> IngestStatus:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT last_ingest_at, last_successful_batch_at, last_error_at, last_error_category
                FROM healthkit_ingest_status WHERE singleton = 1
                """
            ).fetchone()
        return IngestStatus(*row) if row is not None else IngestStatus(None, None, None, None)

    def devices(self) -> list[DeviceStatus]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT device_id, app_version, queue_depth, last_upload_at, client_sent_at
                FROM healthkit_devices ORDER BY last_upload_at DESC, device_id ASC
                """
            ).fetchall()
        return [DeviceStatus(*row) for row in rows]
