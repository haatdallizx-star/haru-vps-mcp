#!/usr/bin/env python3
"""Send one non-sensitive synthetic HealthKit sample to a deployed ingest endpoint."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def main() -> int:
    url = os.environ.get("HARU_HEALTHKIT_PROBE_URL")
    token = os.environ.get("HARU_HEALTHKIT_PROBE_TOKEN")
    if not url or not token:
        print("HARU_HEALTHKIT_PROBE_URL and HARU_HEALTHKIT_PROBE_TOKEN are required", file=sys.stderr)
        return 2

    sample_id = str(uuid4())
    now = _utc_now()
    body = json.dumps(
        {
            "schema_version": 1,
            "device_id": "healthkit-probe",
            "sent_at": now,
            "samples": [
                {
                    "uuid": sample_id,
                    "type": "heart_rate",
                    "value": 72.0,
                    "unit": "bpm",
                    "start_at": now,
                    "end_at": now,
                    "queued_at": now,
                    "source_name": "healthkit-probe",
                    "source_bundle": None,
                    "device": None,
                    "metadata": {"HKWasUserEntered": True},
                }
            ],
        },
        separators=(",", ":"),
    ).encode("utf-8")

    request = Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=15) as response:
            status = response.status
            payload = json.loads(response.read())
    except HTTPError as exc:
        print(f"HealthKit probe failed with HTTP {exc.code}", file=sys.stderr)
        return 1
    except (URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"HealthKit probe failed: {type(exc).__name__}", file=sys.stderr)
        return 1

    if status != 200:
        print(f"HealthKit probe expected HTTP 200, got {status}", file=sys.stderr)
        return 1
    accepted = payload.get("accepted")
    duplicates = payload.get("duplicates")
    if not isinstance(accepted, int) or not isinstance(duplicates, int) or accepted + duplicates != 1:
        print("HealthKit probe response contract mismatch", file=sys.stderr)
        return 1

    print(f"healthkit_ingest_probe=PASS accepted={accepted} duplicates={duplicates}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
