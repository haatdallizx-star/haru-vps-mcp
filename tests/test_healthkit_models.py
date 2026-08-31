import pytest

from healthkit_ingest.models import (
    IngestBatch,
    NumericSample,
    PayloadValidationError,
    SleepSample,
    parse_batch,
)


def numeric_sample(**overrides):
    sample = {
        "uuid": "11111111-1111-1111-1111-111111111111",
        "type": "heart_rate",
        "value": 72.0,
        "unit": "bpm",
        "start_at": "2026-08-31T13:00:00+08:00",
        "end_at": "2026-08-31T13:00:05+08:00",
        "queued_at": "2026-08-31T13:00:10+08:00",
        "source_name": "Apple Watch",
        "source_bundle": "com.apple.health",
        "device": "Apple Watch",
        "metadata": {},
    }
    sample.update(overrides)
    return sample


def sleep_sample(**overrides):
    sample = {
        "uuid": "22222222-2222-2222-2222-222222222222",
        "type": "sleep",
        "stage": "core",
        "start_at": "2026-08-31T00:00:00+08:00",
        "end_at": "2026-08-31T01:00:00+08:00",
        "queued_at": "2026-08-31T01:00:05+08:00",
        "source_name": "Apple Watch",
        "source_bundle": "com.apple.health",
        "device": "Apple Watch",
        "metadata": {},
    }
    sample.update(overrides)
    return sample


def batch(samples):
    return {
        "schema_version": 1,
        "device_id": "installation-1",
        "sent_at": "2026-08-31T13:00:20+08:00",
        "samples": samples,
    }


def test_numeric_sample_is_normalized_to_utc():
    parsed = parse_batch(batch([numeric_sample()]), max_batch_samples=800)
    sample = parsed.samples[0]
    assert isinstance(sample, NumericSample)
    assert sample.start_at == "2026-08-31T05:00:00Z"
    assert sample.end_at == "2026-08-31T05:00:05Z"
    assert sample.queued_at == "2026-08-31T05:00:10Z"
    assert parsed.sent_at == "2026-08-31T05:00:20Z"


def test_sleep_stage_remains_interval_data():
    parsed = parse_batch(batch([sleep_sample()]), max_batch_samples=800)
    sample = parsed.samples[0]
    assert isinstance(sample, SleepSample)
    assert sample.stage == "core"
    assert sample.stage_raw == "core"
    assert sample.start_at != sample.end_at


def test_only_phase_one_types_are_accepted():
    with pytest.raises(PayloadValidationError, match="unsupported sample type"):
        parse_batch(batch([numeric_sample(type="oxygen_saturation")]), max_batch_samples=800)


@pytest.mark.parametrize(
    ("sample_type", "unit"),
    [("heart_rate", "count"), ("hrv", "bpm"), ("steps", "ms")],
)
def test_numeric_type_requires_canonical_unit(sample_type, unit):
    with pytest.raises(PayloadValidationError, match="canonical unit"):
        parse_batch(batch([numeric_sample(type=sample_type, unit=unit)]), max_batch_samples=800)


def test_sleep_rejects_numeric_value_and_unit():
    with pytest.raises(PayloadValidationError, match="sleep sample"):
        parse_batch(batch([sleep_sample(value=1, unit="count")]), max_batch_samples=800)


def test_unknown_sleep_stage_is_preserved_as_raw_value():
    parsed = parse_batch(batch([sleep_sample(stage="future-stage")]), max_batch_samples=800)
    sample = parsed.samples[0]
    assert isinstance(sample, SleepSample)
    assert sample.stage == "unknown"
    assert sample.stage_raw == "future-stage"


def test_uuid_must_be_nonempty_string():
    with pytest.raises(PayloadValidationError, match="uuid"):
        parse_batch(batch([numeric_sample(uuid="")]), max_batch_samples=800)


def test_end_must_not_precede_start():
    with pytest.raises(PayloadValidationError, match="end_at"):
        parse_batch(
            batch([numeric_sample(start_at="2026-08-31T05:00:10Z", end_at="2026-08-31T05:00:00Z")]),
            max_batch_samples=800,
        )


def test_naive_timestamp_is_rejected():
    with pytest.raises(PayloadValidationError, match="timezone"):
        parse_batch(batch([numeric_sample(start_at="2026-08-31T05:00:00")]), max_batch_samples=800)


def test_schema_version_must_equal_one():
    payload = batch([numeric_sample()])
    payload["schema_version"] = 2
    with pytest.raises(PayloadValidationError, match="schema_version"):
        parse_batch(payload, max_batch_samples=800)


def test_batch_may_not_exceed_800_samples():
    samples = [numeric_sample(uuid=f"sample-{i}") for i in range(801)]
    with pytest.raises(PayloadValidationError, match="too many samples"):
        parse_batch(batch(samples), max_batch_samples=800)


def test_metadata_must_be_json_object_and_is_allowlisted():
    parsed = parse_batch(
        batch(
            [
                numeric_sample(
                    metadata={
                        "HKWasUserEntered": True,
                        "HKMetadataKeyHeartRateMotionContext": 2,
                        "private_or_unknown": "drop-me",
                    }
                )
            ]
        ),
        max_batch_samples=800,
    )
    sample = parsed.samples[0]
    assert sample.metadata == {
        "HKWasUserEntered": True,
        "HKMetadataKeyHeartRateMotionContext": 2,
    }
    with pytest.raises(PayloadValidationError, match="metadata"):
        parse_batch(batch([numeric_sample(metadata=["not", "an", "object"])]), max_batch_samples=800)


def test_device_id_and_samples_shape_are_required():
    payload = batch([numeric_sample()])
    payload["device_id"] = ""
    with pytest.raises(PayloadValidationError, match="device_id"):
        parse_batch(payload, max_batch_samples=800)

    payload = batch([numeric_sample()])
    payload["samples"] = "not-a-list"
    with pytest.raises(PayloadValidationError, match="samples"):
        parse_batch(payload, max_batch_samples=800)
