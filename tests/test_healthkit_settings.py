from pathlib import Path

import pytest

from healthkit_ingest.settings import HealthKitSettingsError, load_healthkit_settings


def base_env(tmp_path: Path) -> dict[str, str]:
    return {
        "HARU_HEALTHKIT_TOKEN": "test-secret-token",
        "HARU_HEALTHKIT_DB": str(tmp_path / "healthkit.sqlite3"),
    }


def test_defaults_are_loopback_and_isolated(tmp_path):
    cfg = load_healthkit_settings(env=base_env(tmp_path))
    assert cfg.host == "127.0.0.1"
    assert cfg.port == 8770
    assert cfg.database_path == tmp_path / "healthkit.sqlite3"
    assert cfg.max_batch_samples == 800
    assert cfg.max_body_bytes == 2_000_000


def test_token_is_required(tmp_path):
    env = base_env(tmp_path)
    del env["HARU_HEALTHKIT_TOKEN"]
    with pytest.raises(HealthKitSettingsError, match="HARU_HEALTHKIT_TOKEN"):
        load_healthkit_settings(env=env)


def test_empty_token_is_rejected(tmp_path):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_TOKEN": ""}
    with pytest.raises(HealthKitSettingsError, match="HARU_HEALTHKIT_TOKEN"):
        load_healthkit_settings(env=env)


@pytest.mark.parametrize(
    "token",
    [
        "REPLACE_WITH_A_RANDOM_SECRET_AT_LEAST_32_CHARS",
        "   test-secret-token   ",
        "x" * 32,
    ],
)
def test_known_or_clearly_invalid_token_is_rejected(tmp_path, token):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_TOKEN": token}
    with pytest.raises(HealthKitSettingsError, match="HARU_HEALTHKIT_TOKEN") as exc:
        load_healthkit_settings(env=env)
    assert token not in str(exc.value)


def test_short_token_is_rejected_without_echoing_secret(tmp_path):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_TOKEN": "too-short"}
    with pytest.raises(HealthKitSettingsError) as exc:
        load_healthkit_settings(env=env)
    assert "HARU_HEALTHKIT_TOKEN" in str(exc.value)
    assert "too-short" not in str(exc.value)


def test_non_loopback_bind_is_rejected(tmp_path):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_HOST": "0.0.0.0"}
    with pytest.raises(HealthKitSettingsError, match="loopback"):
        load_healthkit_settings(env=env)


@pytest.mark.parametrize("value", ["0", "65536", "not-a-number"])
def test_invalid_port_is_rejected(tmp_path, value):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_PORT": value}
    with pytest.raises(HealthKitSettingsError, match="HARU_HEALTHKIT_PORT"):
        load_healthkit_settings(env=env)


def test_relative_database_path_is_rejected(tmp_path):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_DB": "relative.sqlite3"}
    with pytest.raises(HealthKitSettingsError, match="absolute"):
        load_healthkit_settings(env=env)


@pytest.mark.parametrize("name", ["HARU_HEALTHKIT_MAX_BATCH_SAMPLES", "HARU_HEALTHKIT_MAX_BODY_BYTES"])
@pytest.mark.parametrize("value", ["0", "-1", "not-a-number"])
def test_nonpositive_or_invalid_limits_are_rejected(tmp_path, name, value):
    env = base_env(tmp_path) | {name: value}
    with pytest.raises(HealthKitSettingsError, match=name):
        load_healthkit_settings(env=env)


def test_token_is_hidden_from_settings_repr(tmp_path):
    cfg = load_healthkit_settings(env=base_env(tmp_path))
    assert "test-secret-token" not in repr(cfg)
