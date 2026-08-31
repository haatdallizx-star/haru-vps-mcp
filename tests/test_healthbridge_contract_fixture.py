import json
from pathlib import Path

from healthkit_ingest.models import parse_batch


def test_healthbridge_schema_v1_fixture_matches_server_contract():
    fixture = Path(__file__).resolve().parents[1] / "docs" / "fixtures" / "healthbridge-schema-v1.json"
    payload = json.loads(fixture.read_text(encoding="utf-8"))
    batch = parse_batch(payload, max_batch_samples=800)
    assert batch.device_id == "fixture-installation"
    assert batch.app_version == "0.1.0"
    assert batch.queue_depth == 2
    assert batch.samples[0].type == "heart_rate"
    assert batch.deletions[0].metric == "sleep"
    assert batch.aggregates[0].metric == "steps"
    assert batch.aggregates[0].unit == "count"
