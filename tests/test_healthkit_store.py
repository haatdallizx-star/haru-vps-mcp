import sqlite3
import threading
import time
from datetime import datetime, timezone

import pytest

from healthkit_ingest.models import parse_batch
from healthkit_ingest.store import HealthKitStore


def payload(samples):
    return {
        "schema_version": 1,
        "device_id": "installation-1",
        "sent_at": "2026-08-31T05:00:20Z",
        "samples": samples,
    }


def numeric(uuid="numeric-1"):
    return {
        "uuid": uuid,
        "type": "heart_rate",
        "value": 72,
        "unit": "bpm",
        "start_at": "2026-08-31T05:00:00Z",
        "end_at": "2026-08-31T05:00:05Z",
        "queued_at": "2026-08-31T05:00:10Z",
        "source_name": "Apple Watch",
        "source_bundle": "com.apple.health",
        "device": "Apple Watch",
        "metadata": {},
    }


def sleep(uuid="sleep-1"):
    return {
        "uuid": uuid,
        "type": "sleep",
        "stage": "core",
        "start_at": "2026-08-31T00:00:00Z",
        "end_at": "2026-08-31T01:00:00Z",
        "queued_at": "2026-08-31T01:00:05Z",
        "source_name": "Apple Watch",
        "source_bundle": "com.apple.health",
        "device": "Apple Watch",
        "metadata": {},
    }


def _insert_legacy_numeric(conn, *, uuid, sample_type="heart_rate"):
    conn.execute(
        """
        INSERT INTO healthkit_numeric_samples (
            uuid, type, value, unit, start_at, end_at, source_name, source_bundle,
            device, metadata_json, queued_at, received_at
        ) VALUES (?, ?, 72, 'bpm', '2026-08-31T05:00:00Z', '2026-08-31T05:00:05Z',
                  NULL, NULL, NULL, '{}', '2026-08-31T05:00:10Z', '2026-08-31T05:00:20Z')
        """,
        (uuid, sample_type),
    )


def _insert_legacy_sleep(conn, *, uuid):
    conn.execute(
        """
        INSERT INTO healthkit_sleep_samples (
            uuid, stage, stage_raw, start_at, end_at, source_name, source_bundle,
            device, metadata_json, queued_at, received_at
        ) VALUES (?, 'core', 'core', '2026-08-31T00:00:00Z', '2026-08-31T01:00:00Z',
                  NULL, NULL, NULL, '{}', '2026-08-31T01:00:05Z', '2026-08-31T05:00:20Z')
        """,
        (uuid,),
    )


def test_initialize_creates_only_healthkit_tables(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    with sqlite3.connect(path) as conn:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert tables == {
        "healthkit_sample_uuids",
        "healthkit_numeric_samples",
        "healthkit_sleep_samples",
        "healthkit_ingest_status",
    }
    assert not any(name in tables for name in {"health_samples", "heart_rate", "sleep", "steps"})


def test_initialize_backfills_clean_pre_registry_legacy_database(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    with sqlite3.connect(path) as conn:
        conn.execute("DROP TABLE healthkit_sample_uuids")
        _insert_legacy_numeric(conn, uuid="legacy-numeric")
        _insert_legacy_sleep(conn, uuid="legacy-sleep")

    store.initialize()

    with sqlite3.connect(path) as conn:
        registry = conn.execute(
            "SELECT uuid, sample_type FROM healthkit_sample_uuids ORDER BY uuid"
        ).fetchall()
    assert registry == [("legacy-numeric", "heart_rate"), ("legacy-sleep", "sleep")]


def test_initialize_rejects_cross_table_legacy_uuid_collision_without_mutating_data(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    with sqlite3.connect(path) as conn:
        conn.execute("DROP TABLE healthkit_sample_uuids")
        _insert_legacy_numeric(conn, uuid="sensitive-collision-uuid")
        _insert_legacy_sleep(conn, uuid="sensitive-collision-uuid")

    with pytest.raises(RuntimeError) as caught:
        store.initialize()

    assert str(caught.value) == "HealthKit database integrity check failed"
    assert "sensitive-collision-uuid" not in str(caught.value)
    with sqlite3.connect(path) as conn:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert conn.execute("SELECT COUNT(*) FROM healthkit_numeric_samples").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM healthkit_sleep_samples").fetchone()[0] == 1
    assert "healthkit_sample_uuids" not in tables


@pytest.mark.parametrize(
    ("stored_kind", "registry_type"),
    [("numeric", "sleep"), ("sleep", "heart_rate")],
)
def test_initialize_rejects_existing_registry_type_mismatch(tmp_path, stored_kind, registry_type):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    with sqlite3.connect(path) as conn:
        if stored_kind == "numeric":
            _insert_legacy_numeric(conn, uuid="mismatched-registry-uuid")
        else:
            _insert_legacy_sleep(conn, uuid="mismatched-registry-uuid")
        conn.execute(
            "INSERT INTO healthkit_sample_uuids (uuid, sample_type) VALUES (?, ?)",
            ("mismatched-registry-uuid", registry_type),
        )

    with pytest.raises(RuntimeError) as caught:
        store.initialize()

    assert str(caught.value) == "HealthKit database integrity check failed"
    assert "mismatched-registry-uuid" not in str(caught.value)


def test_numeric_and_sleep_samples_are_stored_separately(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    batch = parse_batch(payload([numeric(), sleep()]), max_batch_samples=800)
    result = store.ingest(batch, received_at=datetime(2026, 8, 31, 5, 1, tzinfo=timezone.utc))
    assert result.accepted == 2
    assert result.duplicates == 0
    with sqlite3.connect(path) as conn:
        assert conn.execute("SELECT COUNT(*) FROM healthkit_numeric_samples").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM healthkit_sleep_samples").fetchone()[0] == 1


def test_replaying_same_uuid_is_idempotent(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    batch = parse_batch(payload([numeric()]), max_batch_samples=800)
    first = store.ingest(batch, received_at=datetime.now(timezone.utc))
    second = store.ingest(batch, received_at=datetime.now(timezone.utc))
    assert (first.accepted, first.duplicates) == (1, 0)
    assert (second.accepted, second.duplicates) == (0, 1)


def test_mixed_new_and_duplicate_batch_reports_counts(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    store.ingest(parse_batch(payload([numeric("same")]), max_batch_samples=800), received_at=datetime.now(timezone.utc))
    result = store.ingest(
        parse_batch(payload([numeric("same"), numeric("new")]), max_batch_samples=800),
        received_at=datetime.now(timezone.utc),
    )
    assert (result.accepted, result.duplicates) == (1, 1)


def test_batch_is_atomic_on_database_error(tmp_path, monkeypatch):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    batch = parse_batch(payload([numeric("one"), numeric("two")]), max_batch_samples=800)
    original = store._insert_numeric
    calls = 0

    def broken(conn, sample, received_at):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise sqlite3.DatabaseError("boom")
        return original(conn, sample, received_at)

    monkeypatch.setattr(store, "_insert_numeric", broken)
    with pytest.raises(sqlite3.DatabaseError):
        store.ingest(batch, received_at=datetime.now(timezone.utc))
    with sqlite3.connect(store.path) as conn:
        assert conn.execute("SELECT COUNT(*) FROM healthkit_numeric_samples").fetchone()[0] == 0


def test_received_at_is_server_time_not_client_time(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    received = datetime(2026, 8, 31, 7, 30, tzinfo=timezone.utc)
    store.ingest(parse_batch(payload([numeric()]), max_batch_samples=800), received_at=received)
    with sqlite3.connect(path) as conn:
        stored = conn.execute("SELECT received_at FROM healthkit_numeric_samples").fetchone()[0]
    assert stored == "2026-08-31T07:30:00Z"


def test_status_tracks_last_successful_ingest(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    received = datetime(2026, 8, 31, 7, 30, tzinfo=timezone.utc)
    store.ingest(parse_batch(payload([numeric()]), max_batch_samples=800), received_at=received)
    status = store.status()
    assert status.last_ingest_at == "2026-08-31T07:30:00Z"
    assert status.last_successful_batch_at == "2026-08-31T07:30:00Z"
    assert status.last_error_at is None
    assert status.last_error_category is None


def test_uuid_namespace_is_global_across_numeric_and_sleep(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    received = datetime(2026, 8, 31, 7, 30, tzinfo=timezone.utc)

    first = store.ingest(
        parse_batch(payload([numeric("shared-uuid")]), max_batch_samples=800),
        received_at=received,
    )
    second = store.ingest(
        parse_batch(payload([sleep("shared-uuid")]), max_batch_samples=800),
        received_at=received,
    )

    assert (first.accepted, first.duplicates) == (1, 0)
    assert (second.accepted, second.duplicates) == (0, 1)
    with sqlite3.connect(path) as conn:
        assert conn.execute("SELECT COUNT(*) FROM healthkit_numeric_samples").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM healthkit_sleep_samples").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM healthkit_sample_uuids").fetchone()[0] == 1


def test_last_failure_is_preserved_after_later_success(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    failed_at = datetime(2026, 8, 31, 7, 29, tzinfo=timezone.utc)
    success_at = datetime(2026, 8, 31, 7, 30, tzinfo=timezone.utc)

    store.record_failure(category="validation_failure", occurred_at=failed_at)
    store.ingest(
        parse_batch(payload([numeric()]), max_batch_samples=800),
        received_at=success_at,
    )

    status = store.status()
    assert status.last_ingest_at == "2026-08-31T07:30:00Z"
    assert status.last_successful_batch_at == "2026-08-31T07:30:00Z"
    assert status.last_error_at == "2026-08-31T07:29:00Z"
    assert status.last_error_category == "validation_failure"


def test_write_waits_for_a_short_sqlite_lock_and_then_succeeds(tmp_path):
    path = tmp_path / "healthkit.sqlite3"
    store = HealthKitStore(path)
    store.initialize()
    batch = parse_batch(payload([numeric()]), max_batch_samples=800)
    locker = sqlite3.connect(path)
    locker.execute("BEGIN IMMEDIATE")
    result = []
    errors = []

    def ingest_in_thread():
        try:
            result.append(store.ingest(batch, received_at=datetime.now(timezone.utc)))
        except Exception as exc:  # pragma: no cover - asserted below
            errors.append(exc)

    worker = threading.Thread(target=ingest_in_thread)
    worker.start()
    time.sleep(0.1)
    locker.commit()
    locker.close()
    worker.join(timeout=2)

    assert not worker.is_alive()
    assert errors == []
    assert [(item.accepted, item.duplicates) for item in result] == [(1, 0)]
