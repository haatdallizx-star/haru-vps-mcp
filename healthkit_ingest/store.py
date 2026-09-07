"""Dedicated SQLite persistence for HealthKit ingest data."""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .models import IngestBatch, NumericSample, SleepSample, MenstrualSample


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
CREATE TABLE IF NOT EXISTS healthkit_sample_uuids (
    uuid TEXT PRIMARY KEY,
    sample_type TEXT NOT NULL CHECK(sample_type IN ('heart_rate','hrv','steps','sleep','menstrual_flow'))
);
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
CREATE TABLE IF NOT EXISTS healthkit_menstrual_samples (
    uuid TEXT PRIMARY KEY, flow TEXT NOT NULL, cycle_start INTEGER,
    start_at TEXT NOT NULL, end_at TEXT NOT NULL, source_name TEXT,
    source_bundle TEXT, device TEXT, metadata_json TEXT NOT NULL,
    queued_at TEXT NOT NULL, received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS healthkit_deleted_samples (
    uuid TEXT PRIMARY KEY, sample_type TEXT NOT NULL, received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS healthkit_ingest_status (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    last_ingest_at TEXT,
    last_successful_batch_at TEXT,
    last_error_at TEXT,
    last_error_category TEXT
);
"""

_DATABASE_INTEGRITY_ERROR = "HealthKit database integrity check failed"


def _utc_text(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("received_at must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class HealthKitStore:
    _BUSY_TIMEOUT_SECONDS = 5.0
    _FAILURE_CATEGORIES = frozenset({"validation_failure", "storage_failure"})

    def __init__(self, path: Path):
        self.path = Path(path)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=self._BUSY_TIMEOUT_SECONDS)
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    @staticmethod
    def _has_row(conn: sqlite3.Connection, query: str) -> bool:
        return conn.execute(query).fetchone() is not None

    def _legacy_data_is_ambiguous(self, conn: sqlite3.Connection) -> bool:
        cross_table_collision = self._has_row(
            conn,
            """
            SELECT 1
            FROM healthkit_numeric_samples AS numeric
            JOIN healthkit_sleep_samples AS sleep ON sleep.uuid = numeric.uuid
            LIMIT 1
            """,
        )
        unsupported_numeric_type = self._has_row(
            conn,
            """
            SELECT 1
            FROM healthkit_numeric_samples
            WHERE type NOT IN ('heart_rate', 'hrv', 'steps')
            LIMIT 1
            """,
        )
        return cross_table_collision or unsupported_numeric_type

    def _registry_is_inconsistent(self, conn: sqlite3.Connection) -> bool:
        # Exactly one typed row must back every registry entry.
        return self._has_row(conn, """
            SELECT 1 FROM healthkit_sample_uuids AS r
            LEFT JOIN healthkit_numeric_samples n ON n.uuid=r.uuid
            LEFT JOIN healthkit_sleep_samples s ON s.uuid=r.uuid
            LEFT JOIN healthkit_menstrual_samples m ON m.uuid=r.uuid
            WHERE ((n.uuid IS NOT NULL)+(s.uuid IS NOT NULL)+(m.uuid IS NOT NULL)) != 1
              OR (r.sample_type='sleep' AND s.uuid IS NULL)
              OR (r.sample_type='menstrual_flow' AND m.uuid IS NULL)
              OR (r.sample_type NOT IN ('sleep','menstrual_flow') AND (n.uuid IS NULL OR n.type != r.sample_type))
            LIMIT 1
        """)

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(f"BEGIN IMMEDIATE;\n{_SCHEMA}")
            registry_sql = conn.execute("SELECT sql FROM sqlite_master WHERE name='healthkit_sample_uuids'").fetchone()[0]
            if "menstrual_flow" not in registry_sql:
                conn.execute("ALTER TABLE healthkit_sample_uuids RENAME TO healthkit_sample_uuids_v1")
                conn.execute("CREATE TABLE healthkit_sample_uuids (uuid TEXT PRIMARY KEY, sample_type TEXT NOT NULL CHECK(sample_type IN ('heart_rate','hrv','steps','sleep','menstrual_flow')))")
                conn.execute("INSERT INTO healthkit_sample_uuids SELECT * FROM healthkit_sample_uuids_v1")
                conn.execute("DROP TABLE healthkit_sample_uuids_v1")
            if self._legacy_data_is_ambiguous(conn):
                raise RuntimeError(_DATABASE_INTEGRITY_ERROR)

            conn.execute(
                """
                INSERT OR IGNORE INTO healthkit_sample_uuids (uuid, sample_type)
                SELECT uuid, type FROM healthkit_numeric_samples
                """
            )
            conn.execute(
                """
                INSERT OR IGNORE INTO healthkit_sample_uuids (uuid, sample_type)
                SELECT uuid, 'sleep' FROM healthkit_sleep_samples
                """
            )
            conn.execute("INSERT OR IGNORE INTO healthkit_sample_uuids SELECT uuid, 'menstrual_flow' FROM healthkit_menstrual_samples")
            if self._registry_is_inconsistent(conn):
                raise RuntimeError(_DATABASE_INTEGRITY_ERROR)

            conn.execute(
                """
                INSERT INTO healthkit_ingest_status (
                    singleton, last_ingest_at, last_successful_batch_at, last_error_at, last_error_category
                ) VALUES (1, NULL, NULL, NULL, NULL)
                ON CONFLICT(singleton) DO NOTHING
                """
            )

    def _claim_uuid(self, conn: sqlite3.Connection, *, uuid: str, sample_type: str) -> bool:
        cursor = conn.execute(
            """
            INSERT INTO healthkit_sample_uuids (uuid, sample_type) VALUES (?, ?)
            ON CONFLICT(uuid) DO NOTHING
            """,
            (uuid, sample_type),
        )
        return cursor.rowcount == 1

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

    def _insert_menstrual(self, conn, sample, received_at):
        conn.execute("""INSERT INTO healthkit_menstrual_samples
            (uuid, flow, cycle_start, start_at, end_at, source_name, source_bundle,
             device, metadata_json, queued_at, received_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
            (sample.uuid, sample.flow, sample.cycle_start, sample.start_at, sample.end_at,
             sample.source_name, sample.source_bundle, sample.device,
             json.dumps(sample.metadata, separators=(",", ":")), sample.queued_at, received_at))
        return True

    def _delete_sample(self, conn, sample, received_at):
        row = conn.execute("SELECT sample_type FROM healthkit_sample_uuids WHERE uuid=?", (sample.uuid,)).fetchone()
        tombstone = conn.execute("SELECT sample_type FROM healthkit_deleted_samples WHERE uuid=?", (sample.uuid,)).fetchone()
        if any(r is not None and r[0] != sample.type for r in (row, tombstone)):
            raise sqlite3.IntegrityError("deleted UUID type mismatch")
        conn.execute("INSERT OR IGNORE INTO healthkit_deleted_samples VALUES (?,?,?)", (sample.uuid, sample.type, received_at))
        table = {"sleep": "healthkit_sleep_samples", "menstrual_flow": "healthkit_menstrual_samples"}.get(sample.type, "healthkit_numeric_samples")
        conn.execute(f"DELETE FROM {table} WHERE uuid=?", (sample.uuid,))
        conn.execute("DELETE FROM healthkit_sample_uuids WHERE uuid=?", (sample.uuid,))

    def ingest(self, batch: IngestBatch, *, received_at: datetime) -> IngestResult:
        received_text = _utc_text(received_at)
        accepted = 0
        duplicates = 0
        with self._connect() as conn:
            # Lock before reading tombstones: concurrent writers must not insert
            # a deletion between the check and the UUID claim.
            conn.execute("BEGIN IMMEDIATE")
            # Tombstones win even when independent background tasks finish out of order.
            for deleted in batch.deleted_samples:
                self._delete_sample(conn, deleted, received_text)
            for sample in batch.samples:
                if conn.execute("SELECT 1 FROM healthkit_deleted_samples WHERE uuid=?", (sample.uuid,)).fetchone():
                    duplicates += 1
                    continue
                if not self._claim_uuid(conn, uuid=sample.uuid, sample_type=sample.type):
                    duplicates += 1
                    continue
                if isinstance(sample, NumericSample):
                    inserted = self._insert_numeric(conn, sample, received_text)
                elif isinstance(sample, MenstrualSample):
                    inserted = self._insert_menstrual(conn, sample, received_text)
                else:
                    inserted = self._insert_sleep(conn, sample, received_text)
                if not inserted:
                    raise sqlite3.IntegrityError("claimed HealthKit UUID was not inserted")
                accepted += 1
            conn.execute(
                """
                UPDATE healthkit_ingest_status
                SET last_ingest_at = ?,
                    last_successful_batch_at = ?
                WHERE singleton = 1
                """,
                (received_text, received_text),
            )
        return IngestResult(accepted=accepted, duplicates=duplicates)

    def record_failure(self, *, category: str, occurred_at: datetime) -> None:
        if category not in self._FAILURE_CATEGORIES:
            raise ValueError("unsupported HealthKit failure category")
        occurred_text = _utc_text(occurred_at)
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE healthkit_ingest_status
                SET last_ingest_at = ?,
                    last_error_at = ?,
                    last_error_category = ?
                WHERE singleton = 1
                """,
                (occurred_text, occurred_text, category),
            )

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
