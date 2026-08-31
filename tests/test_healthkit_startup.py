from __future__ import annotations

import http.client
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOKEN = "real-stack-secret-token-123456"


def _free_loopback_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _wait_for_listener(process: subprocess.Popen, port: int) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout is not None else ""
            raise AssertionError(f"HealthKit startup exited early:\n{output}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError("HealthKit startup did not open its loopback listener")


def _post(port: int, *, token: str, forwarded_for: str, body: bytes) -> tuple[int, dict]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request(
            "POST",
            "/healthkit/v1/ingest",
            body=body,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "X-Forwarded-For": forwarded_for,
            },
        )
        response = connection.getresponse()
        payload = json.loads(response.read())
        return response.status, payload
    finally:
        connection.close()


def _valid_payload() -> bytes:
    return json.dumps(
        {
            "schema_version": 1,
            "device_id": "real-startup-regression",
            "sent_at": "2026-08-31T08:30:00Z",
            "samples": [
                {
                    "uuid": "real-startup-valid-after-failures",
                    "type": "heart_rate",
                    "value": 72,
                    "unit": "bpm",
                    "start_at": "2026-08-31T08:29:00Z",
                    "end_at": "2026-08-31T08:29:05Z",
                    "queued_at": "2026-08-31T08:29:10Z",
                    "metadata": {},
                }
            ],
        }
    ).encode()


def test_real_startup_stack_limits_rotating_xff_but_allows_valid_token(tmp_path):
    port = _free_loopback_port()
    env = os.environ.copy()
    env.update(
        {
            "HARU_HEALTHKIT_HOST": "127.0.0.1",
            "HARU_HEALTHKIT_PORT": str(port),
            "HARU_HEALTHKIT_DB": str(tmp_path / "healthkit.sqlite3"),
            "HARU_HEALTHKIT_TOKEN": TOKEN,
            "PYTHONUNBUFFERED": "1",
        }
    )
    process = subprocess.Popen(
        [sys.executable, "-m", "healthkit_ingest.main"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        _wait_for_listener(process, port)
        statuses = [
            _post(
                port,
                token="wrong-token-xxxxxxxx",
                forwarded_for=f"198.51.100.{index}",
                body=b"must-not-be-read",
            )[0]
            for index in range(1, 7)
        ]
        valid_status, valid_payload = _post(
            port,
            token=TOKEN,
            forwarded_for="198.51.100.99",
            body=_valid_payload(),
        )
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    assert statuses == [401, 401, 401, 401, 401, 429]
    assert valid_status == 200
    assert valid_payload == {"accepted": 1, "duplicates": 0, "rejected": 0}
