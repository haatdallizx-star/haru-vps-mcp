"""Backward-compatible schema-v1/v2 HealthKit payload parsing and normalization."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import math
from typing import Any, Mapping

NUMERIC_UNITS = {
    "heart_rate": "bpm",
    "hrv": "ms",
    "steps": "count",
}
SUPPORTED_TYPES = frozenset({*NUMERIC_UNITS, "sleep", "menstrual_flow"})
ALLOWED_METADATA_KEYS = frozenset({
    "HKWasUserEntered",
    "HKTimeZone",
    "HKMetadataKeyHeartRateMotionContext",
})
KNOWN_SLEEP_STAGES = frozenset({"awake", "core", "deep", "rem", "asleep", "in_bed"})


class PayloadValidationError(ValueError):
    """Safe validation error suitable for mapping to a client response."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class NumericSample:
    uuid: str
    type: str
    value: float
    unit: str
    start_at: str
    end_at: str
    queued_at: str
    source_name: str | None
    source_bundle: str | None
    device: str | None
    metadata: dict[str, Any]


@dataclass(frozen=True)
class SleepSample:
    uuid: str
    type: str
    stage: str
    stage_raw: str
    start_at: str
    end_at: str
    queued_at: str
    source_name: str | None
    source_bundle: str | None
    device: str | None
    metadata: dict[str, Any]


@dataclass(frozen=True)
class MenstrualSample:
    uuid: str
    type: str
    flow: str
    cycle_start: bool | None
    start_at: str
    end_at: str
    queued_at: str
    source_name: str | None
    source_bundle: str | None
    device: str | None
    metadata: dict[str, Any]


@dataclass(frozen=True)
class DeletedSample:
    uuid: str
    type: str


@dataclass(frozen=True)
class IngestBatch:
    schema_version: int
    device_id: str
    sent_at: str
    samples: tuple[NumericSample | SleepSample | MenstrualSample, ...]
    deleted_samples: tuple[DeletedSample, ...] = ()


def _require_object(value: object, *, field_name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise PayloadValidationError("invalid_payload", f"{field_name} must be a JSON object")
    return value


def _require_nonempty_string(value: object, *, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PayloadValidationError("invalid_payload", f"{field_name} must be a nonempty string")
    return value


def _optional_string(value: object, *, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise PayloadValidationError("invalid_payload", f"{field_name} must be a string or null")
    return value


def _parse_aware_datetime(value: object, *, field_name: str) -> tuple[datetime, str]:
    raw = _require_nonempty_string(value, field_name=field_name)
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        raise PayloadValidationError("invalid_timestamp", f"{field_name} must be ISO-8601") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise PayloadValidationError("invalid_timestamp", f"{field_name} must include a timezone")
    try:
        utc = parsed.astimezone(timezone.utc)
    except OverflowError:
        raise PayloadValidationError(
            "invalid_timestamp",
            f"{field_name} must normalize within the supported datetime range",
        ) from None
    normalized = utc.isoformat().replace("+00:00", "Z")
    return utc, normalized


def _parse_metadata(value: object) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise PayloadValidationError("invalid_metadata", "metadata must be a JSON object")
    return {key: value[key] for key in ALLOWED_METADATA_KEYS if key in value}


def _shared_sample_fields(sample: Mapping[str, Any]) -> dict[str, Any]:
    uuid = _require_nonempty_string(sample.get("uuid"), field_name="uuid")
    start_dt, start_at = _parse_aware_datetime(sample.get("start_at"), field_name="start_at")
    end_dt, end_at = _parse_aware_datetime(sample.get("end_at"), field_name="end_at")
    if end_dt < start_dt:
        raise PayloadValidationError("invalid_interval", "end_at must not precede start_at")
    _, queued_at = _parse_aware_datetime(sample.get("queued_at"), field_name="queued_at")
    return {
        "uuid": uuid,
        "start_at": start_at,
        "end_at": end_at,
        "queued_at": queued_at,
        "source_name": _optional_string(sample.get("source_name"), field_name="source_name"),
        "source_bundle": _optional_string(sample.get("source_bundle"), field_name="source_bundle"),
        "device": _optional_string(sample.get("device"), field_name="device"),
        "metadata": _parse_metadata(sample.get("metadata", {})),
    }


def _parse_numeric_sample(sample: Mapping[str, Any], sample_type: str) -> NumericSample:
    expected_unit = NUMERIC_UNITS[sample_type]
    unit = _require_nonempty_string(sample.get("unit"), field_name="unit")
    if unit != expected_unit:
        raise PayloadValidationError(
            "invalid_unit",
            f"{sample_type} requires canonical unit {expected_unit}",
        )
    value = sample.get("value")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PayloadValidationError("invalid_value", "numeric sample value must be a number")
    try:
        normalized_value = float(value)
    except OverflowError:
        raise PayloadValidationError("invalid_value", "numeric sample value must be representable") from None
    if not math.isfinite(normalized_value):
        raise PayloadValidationError("invalid_value", "numeric sample value must be finite")
    return NumericSample(
        type=sample_type,
        value=normalized_value,
        unit=unit,
        **_shared_sample_fields(sample),
    )


def _parse_sleep_sample(sample: Mapping[str, Any]) -> SleepSample:
    if "value" in sample or "unit" in sample:
        raise PayloadValidationError("invalid_sleep_sample", "sleep sample must not include value or unit")
    stage_raw = _require_nonempty_string(sample.get("stage"), field_name="stage")
    stage = stage_raw if stage_raw in KNOWN_SLEEP_STAGES else "unknown"
    return SleepSample(
        type="sleep",
        stage=stage,
        stage_raw=stage_raw,
        **_shared_sample_fields(sample),
    )


def parse_batch(payload: object, *, max_batch_samples: int) -> IngestBatch:
    root = _require_object(payload, field_name="payload")
    schema_version = root.get("schema_version")
    if type(schema_version) is not int or schema_version not in (1, 2):
        raise PayloadValidationError("unsupported_schema", "schema_version must equal 1 or 2")
    raw_deleted = root.get("deleted_samples", [])
    if not isinstance(raw_deleted, list):
        raise PayloadValidationError("invalid_deletions", "deleted_samples must be an array")
    if schema_version == 1 and raw_deleted:
        raise PayloadValidationError("unsupported_schema", "deletions require schema_version 2")

    device_id = _require_nonempty_string(root.get("device_id"), field_name="device_id")
    _, sent_at = _parse_aware_datetime(root.get("sent_at"), field_name="sent_at")

    raw_samples = root.get("samples")
    if not isinstance(raw_samples, list):
        raise PayloadValidationError("invalid_samples", "samples must be a JSON array")
    if len(raw_samples) + len(raw_deleted) > max_batch_samples:
        raise PayloadValidationError("batch_too_large", "too many samples in batch")

    parsed_samples: list[NumericSample | SleepSample | MenstrualSample] = []
    for index, raw_sample in enumerate(raw_samples):
        sample = _require_object(raw_sample, field_name=f"samples[{index}]")
        sample_type = _require_nonempty_string(sample.get("type"), field_name="type")
        if sample_type not in SUPPORTED_TYPES:
            raise PayloadValidationError("unsupported_type", f"unsupported sample type: {sample_type}")
        if sample_type == "sleep":
            parsed_samples.append(_parse_sleep_sample(sample))
        elif sample_type == "menstrual_flow":
            if schema_version != 2:
                raise PayloadValidationError("unsupported_schema", "menstrual flow requires schema_version 2")
            flow = sample.get("flow")
            if flow not in ("unspecified", "none", "light", "medium", "heavy", "unknown") or "value" in sample or "unit" in sample:
                raise PayloadValidationError("invalid_menstrual_sample", "invalid menstrual flow fields")
            cycle_start = sample.get("cycle_start")
            if cycle_start is not None and type(cycle_start) is not bool:
                raise PayloadValidationError("invalid_menstrual_sample", "cycle_start must be boolean or null")
            parsed_samples.append(MenstrualSample(type=sample_type, flow=flow,
                                                 cycle_start=cycle_start, **_shared_sample_fields(sample)))
        else:
            parsed_samples.append(_parse_numeric_sample(sample, sample_type))

    deleted = []
    for raw in raw_deleted:
        item = _require_object(raw, field_name="deleted_samples entry")
        kind = _require_nonempty_string(item.get("type"), field_name="type")
        if kind not in SUPPORTED_TYPES:
            raise PayloadValidationError("unsupported_type", "unsupported deleted sample type")
        deleted.append(DeletedSample(uuid=_require_nonempty_string(item.get("uuid"), field_name="uuid"), type=kind))

    return IngestBatch(
        schema_version=schema_version,
        device_id=device_id,
        sent_at=sent_at,
        samples=tuple(parsed_samples),
        deleted_samples=tuple(deleted),
    )
