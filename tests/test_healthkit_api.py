import json

from starlette.testclient import TestClient

from healthkit_ingest.app import build_app
from healthkit_ingest.settings import load_healthkit_settings


def settings(tmp_path, **overrides):
    env = {
        "HARU_HEALTHKIT_TOKEN": "test-secret-token",
        "HARU_HEALTHKIT_DB": str(tmp_path / "healthkit.sqlite3"),
    }
    env.update(overrides)
    return load_healthkit_settings(env=env)


def sample(uuid="sample-1"):
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


def payload(samples=None):
    return {
        "schema_version": 1,
        "device_id": "installation-1",
        "sent_at": "2026-08-31T05:00:20Z",
        "samples": [sample()] if samples is None else samples,
    }


def auth(token="test-secret-token"):
    return {"Authorization": f"Bearer {token}"}


def test_valid_batch_returns_200_and_counts(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] == 1
    assert body["duplicates"] == 0
    assert body["deleted"] == 0
    assert body["rejected"] == 0
    assert body["server_time"].endswith("Z")


def test_replay_returns_duplicate_count(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        assert client.post("/healthkit/v1/ingest", json=payload(), headers=auth()).status_code == 200
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth())
    body = response.json()
    assert body["accepted"] == 0
    assert body["duplicates"] == 1
    assert body["deleted"] == 0
    assert body["rejected"] == 0


def test_missing_auth_is_401_without_body_processing(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", content=b"not-json")
    assert response.status_code == 401


def test_wrong_token_is_401(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth("wrong-token-xxxxxxxx"))
    assert response.status_code == 401


def test_unsupported_schema_is_400(tmp_path):
    body = payload()
    body["schema_version"] = 2
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=body, headers=auth())
    assert response.status_code == 400
    assert response.json()["error"] == "unsupported_schema"


def test_malformed_json_is_400(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", content=b"{", headers=auth())
    assert response.status_code == 400
    assert response.json()["error"] == "malformed_json"


def test_more_than_800_samples_is_413(tmp_path):
    body = payload([sample(f"sample-{i}") for i in range(801)])
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=body, headers=auth())
    assert response.status_code == 413


def test_body_over_configured_byte_limit_is_413(tmp_path):
    cfg = settings(tmp_path, HARU_HEALTHKIT_MAX_BODY_BYTES="100")
    raw = json.dumps(payload()).encode()
    assert len(raw) > 100
    with TestClient(build_app(cfg)) as client:
        response = client.post("/healthkit/v1/ingest", content=raw, headers={**auth(), "Content-Type": "application/json"})
    assert response.status_code == 413


def test_validation_error_does_not_write_partial_batch(tmp_path):
    body = payload([sample("valid"), sample("invalid") | {"unit": "count"}])
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", json=body, headers=auth())
        assert response.status_code == 400
        replay = client.post("/healthkit/v1/ingest", json=payload([sample("valid")]), headers=auth())
    assert replay.json()["accepted"] == 1


def test_response_never_contains_configured_token(tmp_path):
    secret = "super-secret-token-12345"
    cfg = settings(tmp_path, HARU_HEALTHKIT_TOKEN=secret)
    with TestClient(build_app(cfg)) as client:
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth(secret))
    assert secret not in response.text
