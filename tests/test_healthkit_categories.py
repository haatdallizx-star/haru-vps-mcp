from datetime import datetime, timezone
import sqlite3

import pytest

from healthkit_ingest.models import parse_batch, PayloadValidationError
from healthkit_ingest.store import HealthKitStore
from healthkit_ingest.query import query_healthkit

NOW = datetime(2026, 9, 7, tzinfo=timezone.utc)


def sample(uuid, kind="sleep", **extra):
    return dict(uuid=uuid, type=kind, start_at="2026-09-06T22:00:00Z",
                end_at="2026-09-07T06:00:00Z", queued_at="2026-09-07T07:00:00Z", **extra)


def batch(samples=(), deleted=()):
    return parse_batch(dict(schema_version=2, device_id="test-device",
                            sent_at="2026-09-07T07:00:00Z", samples=list(samples),
                            deleted_samples=list(deleted)), max_batch_samples=800)


def store_at(tmp_path):
    store = HealthKitStore(tmp_path / "health.sqlite")
    store.initialize()
    return store


def query(store, kind="summary", sample_type="all"):
    return query_healthkit(store.path, kind=kind, sample_type=sample_type,
                          start_at="2026-09-06T23:00:00Z", end_at="2026-09-07T05:00:00Z")


def test_menstrual_record_roundtrip_preserves_flow_and_cycle_start(tmp_path):
    store = store_at(tmp_path)
    record = sample("period", "menstrual_flow", flow="medium", cycle_start=True)
    store.ingest(batch([record]), received_at=NOW)
    result = query(store, "samples", "menstrual_flow")
    assert result["samples"][0]["flow"] == "medium"
    assert result["samples"][0]["cycle_start"] is True
    assert query_healthkit(store.path, kind="status")["counts"]["menstrual_flow"] == 1
    assert query(store)["metrics"]["menstrual_flow"]["cycle_starts"] == 1


def test_sleep_total_excludes_bed_and_awake_and_unions_overlaps(tmp_path):
    store = store_at(tmp_path)
    store.ingest(batch([sample("bed", stage="in_bed"), sample("core", stage="core"),
                        sample("duplicate-source", stage="core"), sample("awake", stage="awake")]), received_at=NOW)
    summary = query(store, sample_type="sleep")["metrics"]["sleep"]
    assert summary["total_hours"] == 6
    assert summary["stages_hours"]["core"] == 6
    assert summary["overlap_conflict_hours"] == 6
    assert summary["count"] == 4


def test_stage_conflicts_do_not_inflate_asleep_total(tmp_path):
    store = store_at(tmp_path)
    store.ingest(batch([sample("core", stage="core"), sample("deep", stage="deep")]), received_at=NOW)
    summary = query(store, sample_type="sleep")["metrics"]["sleep"]
    assert summary["total_hours"] == 6
    assert summary["overlap_conflict_hours"] == 6


@pytest.mark.parametrize("delete_first", [False, True])
def test_deletion_survives_out_of_order_retries_and_restart(tmp_path, delete_first):
    store = store_at(tmp_path)
    record = sample("deleted", "menstrual_flow", flow="light", cycle_start=False)
    deletion = dict(uuid="deleted", type="menstrual_flow")
    if not delete_first:
        store.ingest(batch([record]), received_at=NOW)
    store.ingest(batch(deleted=[deletion]), received_at=NOW)
    store.ingest(batch([record]), received_at=NOW)
    store.initialize()
    assert query(store, "samples", "menstrual_flow")["samples"] == []


def test_deleted_only_batch_and_combined_limit():
    parsed = batch(deleted=[dict(uuid="x", type="sleep")])
    assert len(parsed.deleted_samples) == 1
    with pytest.raises(PayloadValidationError, match="too many"):
        batch([sample(str(i), stage="core") for i in range(800)], [dict(uuid="x", type="sleep")])


def test_legacy_schema_cannot_silently_ignore_deletions():
    with pytest.raises(PayloadValidationError):
        parse_batch(dict(schema_version=1, device_id="d", sent_at="2026-09-07T00:00:00Z",
                         samples=[], deleted_samples=[dict(uuid="x", type="sleep")]), max_batch_samples=800)


@pytest.mark.parametrize("extra", [dict(flow="invalid"), dict(flow="light", cycle_start="true"), dict(flow="heavy", value=3)])
def test_invalid_menstrual_fields_rejected(extra):
    with pytest.raises(PayloadValidationError):
        batch([sample("x", "menstrual_flow", **extra)])


def test_legacy_registry_migrates_without_losing_sleep(tmp_path):
    store = store_at(tmp_path)
    with sqlite3.connect(store.path) as conn:
        conn.execute("DROP TABLE healthkit_sample_uuids")
        conn.execute("CREATE TABLE healthkit_sample_uuids (uuid TEXT PRIMARY KEY, sample_type TEXT NOT NULL CHECK(sample_type IN ('heart_rate','hrv','steps','sleep')))")
    store.initialize()
    store.ingest(batch([sample("s", stage="rem"), sample("m", "menstrual_flow", flow="none")]), received_at=NOW)
    store.initialize()
    assert query_healthkit(store.path, kind="status")["total_samples"] == 2


def test_cross_type_delete_rolls_back_whole_batch(tmp_path):
    store = store_at(tmp_path)
    store.ingest(batch([sample("s", stage="core")]), received_at=NOW)
    with pytest.raises(sqlite3.IntegrityError):
        store.ingest(batch([sample("m", "menstrual_flow", flow="light")],
                           [dict(uuid="s", type="menstrual_flow")]), received_at=NOW)
    assert query_healthkit(store.path, kind="status")["total_samples"] == 1
    assert query(store, "samples", "menstrual_flow")["samples"] == []


def test_sleep_only_awake_and_bed_has_zero_asleep_hours(tmp_path):
    store = store_at(tmp_path)
    store.ingest(batch([sample("b", stage="in_bed"), sample("a", stage="awake")]), received_at=NOW)
    assert query(store, sample_type="sleep")["metrics"]["sleep"]["total_hours"] == 0


def test_zero_duration_menstrual_record_is_not_lost(tmp_path):
    store = store_at(tmp_path)
    item = sample("m", "menstrual_flow", flow="none")
    item["start_at"] = item["end_at"] = "2026-09-07T00:00:00Z"
    store.ingest(batch([item]), received_at=NOW)
    assert query(store, "samples", "menstrual_flow")["samples"][0]["cycle_start"] is None
