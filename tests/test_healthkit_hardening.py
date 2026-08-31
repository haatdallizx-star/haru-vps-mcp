import sqlite3
from datetime import datetime, timezone

from starlette.testclient import TestClient

from healthkit_ingest.app import build_app
from healthkit_ingest.models import parse_batch
from healthkit_ingest.settings import load_healthkit_settings
from healthkit_ingest.store import HealthKitStore


def payload():
    return {
        "schema_version": 1,
        "device_id": "installation-1",
        "app_version": "1.0.0",
        "queue_depth": 3,
        "sent_at": "2026-08-31T05:00:20Z",
        "samples": [{
            "uuid": "sample-1", "type": "heart_rate", "value": 72, "unit": "bpm",
            "start_at": "2026-08-31T05:00:00Z", "end_at": "2026-08-31T05:00:05Z",
            "queued_at": "2026-08-31T05:00:10Z", "metadata": {},
        }],
        "deletions": [{
            "uuid": "old-sample", "metric": "heart_rate", "queued_at": "2026-08-31T05:00:11Z"
        }],
        "aggregates": [{
            "metric": "steps", "bucket_start": "2026-08-31T00:00:00Z",
            "bucket_end": "2026-09-01T00:00:00Z", "value": 4321, "unit": "count",
            "computed_at": "2026-08-31T05:00:12Z", "source": "healthkit_statistics"
        }],
    }


def settings(tmp_path):
    return load_healthkit_settings(env={
        "HARU_HEALTHKIT_TOKEN": "test-secret-token",
        "HARU_HEALTHKIT_DB": str(tmp_path / "healthkit.sqlite3"),
    })


def auth():
    return {"Authorization": "Bearer test-secret-token"}


def test_parser_accepts_device_diagnostics_deletions_and_step_aggregates():
    parsed = parse_batch(payload(), max_batch_samples=800)
    assert parsed.app_version == "1.0.0"
    assert parsed.queue_depth == 3
    assert parsed.deletions[0].uuid == "old-sample"
    assert parsed.deletions[0].metric == "heart_rate"
    assert parsed.aggregates[0].metric == "steps"
    assert parsed.aggregates[0].value == 4321


def test_deletion_marks_existing_sample_deleted_and_is_replay_safe(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    first = payload()
    first["deletions"] = []
    first["aggregates"] = []
    store.ingest(parse_batch(first, max_batch_samples=800), received_at=datetime.now(timezone.utc))

    delete = payload()
    delete["samples"] = []
    delete["aggregates"] = []
    delete["deletions"][0]["uuid"] = "sample-1"
    result = store.ingest(parse_batch(delete, max_batch_samples=800), received_at=datetime.now(timezone.utc))
    replay = store.ingest(parse_batch(delete, max_batch_samples=800), received_at=datetime.now(timezone.utc))
    assert result.deleted == 1
    assert replay.deleted == 0
    with sqlite3.connect(store.path) as conn:
        assert conn.execute("SELECT deleted_at FROM healthkit_numeric_samples WHERE uuid='sample-1'").fetchone()[0]


def test_step_aggregate_upserts_by_device_metric_and_bucket(tmp_path):
    store = HealthKitStore(tmp_path / "healthkit.sqlite3")
    store.initialize()
    batch = parse_batch(payload(), max_batch_samples=800)
    store.ingest(batch, received_at=datetime.now(timezone.utc))
    changed = payload()
    changed["samples"] = []
    changed["deletions"] = []
    changed["aggregates"][0]["value"] = 5000
    store.ingest(parse_batch(changed, max_batch_samples=800), received_at=datetime.now(timezone.utc))
    with sqlite3.connect(store.path) as conn:
        rows = conn.execute("SELECT value FROM healthkit_aggregates").fetchall()
    assert rows == [(5000.0,)]


def test_ingest_response_reports_deletions_and_server_time(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] == 1
    assert body["deleted"] == 1
    assert body["rejected"] == 0
    assert body["server_time"].endswith("Z")


def test_authenticated_status_reports_device_and_queue_state(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        assert client.post("/healthkit/v1/ingest", json=payload(), headers=auth()).status_code == 200
        response = client.get("/healthkit/v1/status", headers=auth())
        unauthorized = client.get("/healthkit/v1/status")
    assert response.status_code == 200
    body = response.json()
    assert body["last_successful_batch_at"] is not None
    assert body["devices"][0]["device_id"] == "installation-1"
    assert body["devices"][0]["app_version"] == "1.0.0"
    assert body["devices"][0]["queue_depth"] == 3
    assert unauthorized.status_code == 401


def test_validation_failure_is_recorded_without_echoing_payload(tmp_path):
    bad = payload()
    bad["samples"][0]["unit"] = "count"
    app = build_app(settings(tmp_path))
    with TestClient(app) as client:
        response = client.post("/healthkit/v1/ingest", json=bad, headers=auth())
    assert response.status_code == 400
    status = app.state.healthkit_store.status()
    assert status.last_error_at is not None
    assert status.last_error_category == "invalid_unit"
