"""Strict settings for the isolated HealthKit ingest service."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8770
DEFAULT_MAX_BATCH_SAMPLES = 800
DEFAULT_MAX_BODY_BYTES = 2_000_000
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


class HealthKitSettingsError(ValueError):
    """Raised when HealthKit ingest configuration is unsafe or invalid."""


@dataclass(frozen=True)
class HealthKitSettings:
    host: str
    port: int
    database_path: Path
    bearer_token: str = field(repr=False)
    max_batch_samples: int = DEFAULT_MAX_BATCH_SAMPLES
    max_body_bytes: int = DEFAULT_MAX_BODY_BYTES


def _parse_positive_int(raw: str, *, field_name: str) -> int:
    try:
        value = int(raw)
    except ValueError:
        raise HealthKitSettingsError(f"{field_name} must be an integer") from None
    if value <= 0:
        raise HealthKitSettingsError(f"{field_name} must be positive")
    return value


def load_healthkit_settings(*, env: Mapping[str, str] | None = None) -> HealthKitSettings:
    raw_env = dict(os.environ if env is None else env)

    host = raw_env.get("HARU_HEALTHKIT_HOST", DEFAULT_HOST)
    if host not in _LOOPBACK_HOSTS:
        raise HealthKitSettingsError("HARU_HEALTHKIT_HOST must be a loopback address")

    port_raw = raw_env.get("HARU_HEALTHKIT_PORT", str(DEFAULT_PORT))
    try:
        port = int(port_raw)
    except ValueError:
        raise HealthKitSettingsError("HARU_HEALTHKIT_PORT must be an integer") from None
    if not 1 <= port <= 65535:
        raise HealthKitSettingsError("HARU_HEALTHKIT_PORT is out of range")

    token = raw_env.get("HARU_HEALTHKIT_TOKEN")
    if token is None or len(token) < 16:
        raise HealthKitSettingsError("HARU_HEALTHKIT_TOKEN must be at least 16 characters")

    database_raw = raw_env.get("HARU_HEALTHKIT_DB")
    if not database_raw:
        raise HealthKitSettingsError("HARU_HEALTHKIT_DB is required")
    database_path = Path(database_raw)
    if not database_path.is_absolute():
        raise HealthKitSettingsError("HARU_HEALTHKIT_DB must be an absolute path")

    max_batch_samples = _parse_positive_int(
        raw_env.get("HARU_HEALTHKIT_MAX_BATCH_SAMPLES", str(DEFAULT_MAX_BATCH_SAMPLES)),
        field_name="HARU_HEALTHKIT_MAX_BATCH_SAMPLES",
    )
    max_body_bytes = _parse_positive_int(
        raw_env.get("HARU_HEALTHKIT_MAX_BODY_BYTES", str(DEFAULT_MAX_BODY_BYTES)),
        field_name="HARU_HEALTHKIT_MAX_BODY_BYTES",
    )

    return HealthKitSettings(
        host=host,
        port=port,
        database_path=database_path,
        bearer_token=token,
        max_batch_samples=max_batch_samples,
        max_body_bytes=max_body_bytes,
    )
