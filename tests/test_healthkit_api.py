import json
import sqlite3

import pytest
from starlette.requests import Request
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
    assert response.json() == {"accepted": 1, "duplicates": 0, "rejected": 0}


def test_replay_returns_duplicate_count(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        assert client.post("/healthkit/v1/ingest", json=payload(), headers=auth()).status_code == 200
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth())
    assert response.json() == {"accepted": 0, "duplicates": 1, "rejected": 0}


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
        response = client.post(
            "/healthkit/v1/ingest",
            content=b"{",
            headers={**auth(), "Content-Type": "application/json"},
        )
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


def test_unauthorized_response_advertises_bearer_auth(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post("/healthkit/v1/ingest", content=b"not-json")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_non_json_media_type_is_415(tmp_path):
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post(
            "/healthkit/v1/ingest",
            content=b"{}",
            headers={**auth(), "Content-Type": "text/plain"},
        )
    assert response.status_code == 415
    assert response.json()["error"] == "unsupported_media_type"


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity"])
def test_non_standard_json_numeric_constants_are_400(tmp_path, constant):
    raw = json.dumps(payload()).replace("72", constant, 1)
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post(
            "/healthkit/v1/ingest",
            content=raw,
            headers={**auth(), "Content-Type": "application/json"},
        )
    assert response.status_code == 400
    assert response.json()["error"] == "malformed_json"


def test_huge_json_integer_is_400_not_storage_500(tmp_path):
    raw = json.dumps(payload()).replace("72", "1" + "0" * 10_000, 1)
    with TestClient(build_app(settings(tmp_path))) as client:
        response = client.post(
            "/healthkit/v1/ingest",
            content=raw,
            headers={**auth(), "Content-Type": "application/json"},
        )
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_value"


def test_validation_failure_is_recorded_and_survives_recovery(tmp_path):
    app = build_app(settings(tmp_path))
    invalid = payload([sample("invalid") | {"unit": "count"}])
    with TestClient(app) as client:
        failed = client.post("/healthkit/v1/ingest", json=invalid, headers=auth())
        recovered = client.post(
            "/healthkit/v1/ingest",
            json=payload([sample("recovered")]),
            headers=auth(),
        )
    status = app.state.healthkit_store.status()
    assert failed.status_code == 400
    assert recovered.status_code == 200
    assert status.last_successful_batch_at is not None
    assert status.last_error_at is not None
    assert status.last_error_category == "validation_failure"


def test_storage_failure_is_recorded_without_leaking_exception(tmp_path, monkeypatch):
    app = build_app(settings(tmp_path))

    def fail_storage(*args, **kwargs):
        raise sqlite3.OperationalError("raw-sensitive-storage-detail")

    monkeypatch.setattr(app.state.healthkit_store, "ingest", fail_storage)
    with TestClient(app) as client:
        response = client.post("/healthkit/v1/ingest", json=payload(), headers=auth())
    status = app.state.healthkit_store.status()
    assert response.status_code == 500
    assert "raw-sensitive-storage-detail" not in response.text
    assert status.last_error_category == "storage_failure"
    assert status.last_error_at is not None


def test_auth_failures_are_limited_per_forwarded_source_from_trusted_proxy(tmp_path):
    app = build_app(settings(tmp_path))
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        for _ in range(5):
            response = client.post(
                "/healthkit/v1/ingest",
                content=b"not-json",
                headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.10"},
            )
            assert response.status_code == 401
        limited = client.post(
            "/healthkit/v1/ingest",
            content=b"not-json",
            headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.10"},
        )
    with TestClient(app, client=("127.0.0.2", 50000)) as other_peer:
        limited_from_other_peer = other_peer.post(
            "/healthkit/v1/ingest",
            content=b"not-json",
            headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.10"},
        )
        other_source = other_peer.post(
            "/healthkit/v1/ingest",
            content=b"not-json",
            headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.11"},
        )
    assert limited.status_code == 429
    assert limited_from_other_peer.status_code == 429
    assert other_source.status_code == 401


def test_untrusted_peer_cannot_select_limiter_source_with_forwarded_header(tmp_path):
    app = build_app(settings(tmp_path))
    with TestClient(app, client=("203.0.113.20", 50000)) as client:
        for index in range(5):
            response = client.post(
                "/healthkit/v1/ingest",
                content=b"not-json",
                headers={
                    **auth("wrong-token-xxxxxxxx"),
                    "X-Forwarded-For": f"198.51.100.{index + 1}",
                },
            )
            assert response.status_code == 401
        limited = client.post(
            "/healthkit/v1/ingest",
            content=b"not-json",
            headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.99"},
        )
    assert limited.status_code == 429


def test_unauthorized_and_limited_requests_do_not_consume_body(tmp_path, monkeypatch):
    app = build_app(settings(tmp_path))

    async def body_must_not_be_read(self):
        raise AssertionError("unauthorized request body was consumed")
        yield b""  # pragma: no cover

    monkeypatch.setattr(Request, "stream", body_must_not_be_read)
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        unauthorized = client.post(
            "/healthkit/v1/ingest",
            headers={**auth("wrong-token-yyyyyyyy"), "X-Forwarded-For": "198.51.100.10"},
        )
        for _ in range(4):
            assert client.post(
                "/healthkit/v1/ingest",
                headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": "198.51.100.10"},
            ).status_code == 401
        limited = client.post(
            "/healthkit/v1/ingest",
            headers={**auth("wrong-token-yyyyyyyy"), "X-Forwarded-For": "198.51.100.10"},
        )
    assert unauthorized.status_code == 401
    assert limited.status_code == 429


def test_rotating_forwarded_sources_hit_immediate_peer_limit_without_reading_body(tmp_path, monkeypatch):
    app = build_app(settings(tmp_path))
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        for index in range(5):
            response = client.post(
                "/healthkit/v1/ingest",
                headers={
                    **auth("wrong-token-xxxxxxxx"),
                    "X-Forwarded-For": f"198.51.100.{index + 1}",
                },
            )
            assert response.status_code == 401

        async def body_must_not_be_read(self):
            raise AssertionError("rate-limited request body was consumed")
            yield b""  # pragma: no cover

        monkeypatch.setattr(Request, "stream", body_must_not_be_read)
        limited = client.post(
            "/healthkit/v1/ingest",
            content=b"must-not-be-read",
            headers={
                **auth("wrong-token-yyyyyyyy"),
                "X-Forwarded-For": "198.51.100.99",
            },
        )
    assert limited.status_code == 429


def test_valid_token_bypasses_full_immediate_peer_failure_bucket(tmp_path):
    app = build_app(settings(tmp_path))
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        for index in range(5):
            assert client.post(
                "/healthkit/v1/ingest",
                headers={
                    **auth("wrong-token-xxxxxxxx"),
                    "X-Forwarded-For": f"198.51.100.{index + 1}",
                },
            ).status_code == 401
        response = client.post(
            "/healthkit/v1/ingest",
            json=payload([sample("valid-after-failures")]),
            headers={**auth(), "X-Forwarded-For": "198.51.100.99"},
        )
    assert response.status_code == 200
    assert response.json() == {"accepted": 1, "duplicates": 0, "rejected": 0}


def test_auth_failure_limiter_keyspace_is_bounded(tmp_path):
    app = build_app(settings(tmp_path))
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        for index in range(1_050):
            source = f"2001:db8::{index:x}"
            response = client.post(
                "/healthkit/v1/ingest",
                headers={**auth("wrong-token-xxxxxxxx"), "X-Forwarded-For": source},
            )
            assert response.status_code in {401, 429}
    assert app.state.auth_failure_limiter.tracked_source_count == 1_024
