import sqlite3

import pytest

from healthkit_ingest.query import query_healthkit


SCHEMA = """
CREATE TABLE healthkit_numeric_samples (
    uuid TEXT PRIMARY KEY, type TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL,
    start_at TEXT NOT NULL, end_at TEXT NOT NULL, source_name TEXT, source_bundle TEXT,
    device TEXT, metadata_json TEXT NOT NULL, queued_at TEXT NOT NULL, received_at TEXT NOT NULL
);
CREATE TABLE healthkit_sleep_samples (
    uuid TEXT PRIMARY KEY, stage TEXT NOT NULL, stage_raw TEXT NOT NULL,
    start_at TEXT NOT NULL, end_at TEXT NOT NULL, source_name TEXT, source_bundle TEXT,
    device TEXT, metadata_json TEXT NOT NULL, queued_at TEXT NOT NULL, received_at TEXT NOT NULL
);
CREATE TABLE healthkit_ingest_status (
    singleton INTEGER PRIMARY KEY, last_ingest_at TEXT, last_successful_batch_at TEXT,
    last_error_at TEXT, last_error_category TEXT
);
"""


def build_database(path):
    with sqlite3.connect(path) as conn:
        conn.executescript(SCHEMA)
        conn.executemany(
            """INSERT INTO healthkit_numeric_samples
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                ("heart-uuid", "heart_rate", 72, "count/min", "2026-09-01T15:00:00Z", "2026-09-01T15:00:05Z", "Watch", "bundle", "device", "{}", "2026-09-01T15:01:00Z", "2026-09-01T15:02:00Z"),
                ("steps-uuid", "steps", 120, "count", "2026-09-01T15:00:00Z", "2026-09-01T15:10:00Z", "Phone", "bundle", "device", "{}", "2026-09-01T15:11:00Z", "2026-09-01T15:12:00Z"),
            ],
        )
        conn.execute(
            """INSERT INTO healthkit_sleep_samples VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("sleep-uuid", "asleep", "HKCategoryValueSleepAnalysisAsleepCore", "2026-09-01T14:00:00Z", "2026-09-01T16:00:00Z", "Watch", "bundle", "device", "{}", "2026-09-01T16:01:00Z", "2026-09-01T16:02:00Z"),
        )
        conn.execute(
            "INSERT INTO healthkit_ingest_status VALUES (1, ?, ?, ?, ?)",
            ("2026-09-01T16:02:00Z", "2026-09-01T16:02:00Z", None, None),
        )


def test_query_reports_when_database_is_not_configured():
    assert query_healthkit(None, kind="status") == {
        "available": False,
        "error": "not_configured",
    }


def test_status_returns_counts_and_freshness_without_identifiers(tmp_path):
    database = tmp_path / "healthkit.sqlite3"
    build_database(database)

    result = query_healthkit(database, kind="status")

    assert result == {
        "available": True,
        "kind": "status",
        "counts": {"heart_rate": 1, "hrv": 0, "steps": 1, "sleep": 1},
        "total_samples": 3,
        "last_sample_at": "2026-09-01T16:00:00Z",
        "last_ingest_at": "2026-09-01T16:02:00Z",
        "last_successful_batch_at": "2026-09-01T16:02:00Z",
        "last_error_at": None,
        "last_error_category": None,
    }
    assert "uuid" not in repr(result)
    assert "metadata" not in repr(result)


def test_summary_aggregates_only_the_requested_window(tmp_path):
    database = tmp_path / "healthkit.sqlite3"
    build_database(database)

    result = query_healthkit(
        database,
        kind="summary",
        sample_type="all",
        start_at="2026-09-01T14:30:00Z",
        end_at="2026-09-01T16:30:00Z",
    )

    assert result == {
        "available": True,
        "kind": "summary",
        "window": {
            "start_at": "2026-09-01T14:30:00Z",
            "end_at": "2026-09-01T16:30:00Z",
        },
        "metrics": {
            "heart_rate": {"count": 1, "unit": "count/min", "minimum": 72.0, "maximum": 72.0, "average": 72.0},
            "steps": {"count": 1, "unit": "count", "total": 120.0},
            "sleep": {"count": 1, "total_hours": 1.5, "stages_hours": {"asleep": 1.5}, "overlap_conflict_hours": 0.0},
        },
    }


def test_samples_are_newest_first_limited_and_sanitized(tmp_path):
    database = tmp_path / "healthkit.sqlite3"
    build_database(database)

    result = query_healthkit(
        database,
        kind="samples",
        sample_type="all",
        start_at="2026-09-01T13:00:00Z",
        end_at="2026-09-01T17:00:00Z",
        limit=2,
    )

    assert result["samples"] == [
        {"type": "sleep", "stage": "asleep", "start_at": "2026-09-01T14:00:00Z", "end_at": "2026-09-01T16:00:00Z"},
        {"type": "steps", "value": 120.0, "unit": "count", "start_at": "2026-09-01T15:00:00Z", "end_at": "2026-09-01T15:10:00Z"},
    ]
    assert result["sample_type"] == "all"
    assert "uuid" not in repr(result)
    assert "source" not in repr(result)
    assert "metadata" not in repr(result)


def test_query_rejects_unsafe_or_unbounded_arguments(tmp_path):
    database = tmp_path / "healthkit.sqlite3"
    build_database(database)

    with pytest.raises(ValueError, match="31 days"):
        query_healthkit(database, kind="summary", start_at="2026-07-01T00:00:00Z", end_at="2026-09-01T00:00:00Z")
    with pytest.raises(ValueError, match="limit"):
        query_healthkit(database, kind="samples", limit=201)
    with pytest.raises(ValueError, match="sample_type"):
        query_healthkit(database, kind="samples", sample_type="raw_sql")
    with pytest.raises(ValueError, match="timezone"):
        query_healthkit(database, kind="summary", start_at="2026-09-01T00:00:00", end_at="2026-09-01T01:00:00Z")


def test_query_hides_database_open_errors(tmp_path):
    result = query_healthkit(tmp_path / "missing.sqlite3", kind="status")
    assert result == {"available": False, "error": "database_unavailable"}
