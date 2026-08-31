"""Schema-v1 HealthKit payload parsing and normalization."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping

NUMERIC_UNITS = {
    "heart_rate": "bpm",
    "hrv": "ms",
    "steps": "count",
}
SUPPORTED_TYPES = frozenset({*NUMERIC_UNITS, "sleep"})
ALLOWED_METADATA_KEYS = frozenset({
    "HKWasUserEntered",
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
    stage_raw: str | int
    start_at: str
    end_at: str
    queued_at: str
    source_name: str | None
    source_bundle: str | None
    device: str | None
    metadata: dict[str, Any]


@dataclass(frozen=True)
class Deletion:
    uuid: str
    metric: str
    queued_at: str


@dataclass(frozen=True)
class StepAggregate:
    metric: str
    bucket_start: str
    bucket_end: str
    value: float
    unit: str
    computed_at: str
    source: str


@dataclass(frozen=True)
class IngestBatch:
    schema_version: int
    device_id: str
    sent_at: str
    samples: tuple[NumericSample | SleepSample, ...]
    deletions: tuple[Deletion, ...] = ()
    aggregates: tuple[StepAggregate, ...] = ()
    app_version: str | None = None
    queue_depth: int | None = None


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


def _optional_nonnegative_int(value: object, *, field_name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PayloadValidationError("invalid_payload", f"{field_name} must be a nonnegative integer or null")
    return value


def _parse_aware_datetime(value: object, *, field_name: str) -> tuple[datetime, str]:
    raw = _require_nonempty_string(value, field_name=field_name)
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        raise PayloadValidationError("invalid_timestamp", f"{field_name} must be ISO-8601") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise PayloadValidationError("invalid_timestamp", f"{field_name} must include a timezone")
    utc = parsed.astimezone(timezone.utc)
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
        raise PayloadValidationError("invalid_unit", f"{sample_type} requires canonical unit {expected_unit}")
    value = sample.get("value")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PayloadValidationError("invalid_value", "numeric sample value must be a number")
    return NumericSample(type=sample_type, value=float(value), unit=unit, **_shared_sample_fields(sample))


def _parse_sleep_sample(sample: Mapping[str, Any]) -> SleepSample:
    if "value" in sample or "unit" in sample:
        raise PayloadValidationError("invalid_sleep_sample", "sleep sample must not include value or unit")
    stage_wire = _require_nonempty_string(sample.get("stage"), field_name="stage")
    stage = stage_wire if stage_wire in KNOWN_SLEEP_STAGES else "unknown"
    stage_raw = sample.get("stage_raw", stage_wire)
    if isinstance(stage_raw, bool) or not isinstance(stage_raw, (str, int)):
        raise PayloadValidationError("invalid_sleep_sample", "stage_raw must be a string or integer")
    return SleepSample(type="sleep", stage=stage, stage_raw=stage_raw, **_shared_sample_fields(sample))


def _parse_deletion(value: object, *, index: int) -> Deletion:
    item = _require_object(value, field_name=f"deletions[{index}]")
    uuid = _require_nonempty_string(item.get("uuid"), field_name="uuid")
    metric = _require_nonempty_string(item.get("metric"), field_name="metric")
    if metric not in SUPPORTED_TYPES:
        raise PayloadValidationError("unsupported_type", f"unsupported deletion metric: {metric}")
    _, queued_at = _parse_aware_datetime(item.get("queued_at"), field_name="queued_at")
    return Deletion(uuid=uuid, metric=metric, queued_at=queued_at)


def _parse_aggregate(value: object, *, index: int) -> StepAggregate:
    item = _require_object(value, field_name=f"aggregates[{index}]")
    metric = _require_nonempty_string(item.get("metric"), field_name="metric")
    if metric != "steps":
        raise PayloadValidationError("unsupported_aggregate", "only steps aggregates are supported in schema v1")
    unit = _require_nonempty_string(item.get("unit"), field_name="unit")
    if unit != "count":
        raise PayloadValidationError("invalid_unit", "steps aggregate requires canonical unit count")
    value_raw = item.get("value")
    if isinstance(value_raw, bool) or not isinstance(value_raw, (int, float)) or value_raw < 0:
        raise PayloadValidationError("invalid_value", "aggregate value must be a nonnegative number")
    start_dt, bucket_start = _parse_aware_datetime(item.get("bucket_start"), field_name="bucket_start")
    end_dt, bucket_end = _parse_aware_datetime(item.get("bucket_end"), field_name="bucket_end")
    if end_dt <= start_dt:
        raise PayloadValidationError("invalid_interval", "bucket_end must follow bucket_start")
    _, computed_at = _parse_aware_datetime(item.get("computed_at"), field_name="computed_at")
    source = _require_nonempty_string(item.get("source"), field_name="source")
    return StepAggregate(
        metric=metric,
        bucket_start=bucket_start,
        bucket_end=bucket_end,
        value=float(value_raw),
        unit=unit,
        computed_at=computed_at,
        source=source,
    )


def parse_batch(payload: object, *, max_batch_samples: int) -> IngestBatch:
    root = _require_object(payload, field_name="payload")
    if root.get("schema_version") != 1:
        raise PayloadValidationError("unsupported_schema", "schema_version must equal 1")

    device_id = _require_nonempty_string(root.get("device_id"), field_name="device_id")
    _, sent_at = _parse_aware_datetime(root.get("sent_at"), field_name="sent_at")
    app_version = _optional_string(root.get("app_version"), field_name="app_version")
    queue_depth = _optional_nonnegative_int(root.get("queue_depth"), field_name="queue_depth")

    raw_samples = root.get("samples")
    if not isinstance(raw_samples, list):
        raise PayloadValidationError("invalid_samples", "samples must be a JSON array")
    raw_deletions = root.get("deletions", [])
    if not isinstance(raw_deletions, list):
        raise PayloadValidationError("invalid_deletions", "deletions must be a JSON array")
    raw_aggregates = root.get("aggregates", [])
    if not isinstance(raw_aggregates, list):
        raise PayloadValidationError("invalid_aggregates", "aggregates must be a JSON array")
    if len(raw_samples) + len(raw_deletions) + len(raw_aggregates) > max_batch_samples:
        raise PayloadValidationError("batch_too_large", "too many records in batch")

    parsed_samples: list[NumericSample | SleepSample] = []
    for index, raw_sample in enumerate(raw_samples):
        sample = _require_object(raw_sample, field_name=f"samples[{index}]")
        sample_type = _require_nonempty_string(sample.get("type"), field_name="type")
        if sample_type not in SUPPORTED_TYPES:
            raise PayloadValidationError("unsupported_type", f"unsupported sample type: {sample_type}")
        parsed_samples.append(_parse_sleep_sample(sample) if sample_type == "sleep" else _parse_numeric_sample(sample, sample_type))

    deletions = tuple(_parse_deletion(item, index=index) for index, item in enumerate(raw_deletions))
    aggregates = tuple(_parse_aggregate(item, index=index) for index, item in enumerate(raw_aggregates))
    return IngestBatch(
        schema_version=1,
        device_id=device_id,
        sent_at=sent_at,
        samples=tuple(parsed_samples),
        deletions=deletions,
        aggregates=aggregates,
        app_version=app_version,
        queue_depth=queue_depth,
    )
