from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from urllib.request import Request

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "probe-healthkit-ingest.py"
SPEC = importlib.util.spec_from_file_location("healthkit_probe", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class FakeResponse:
    status = 200

    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class FakeOpener:
    def __init__(self, response):
        self.response = response
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        return self.response


def configure_probe(monkeypatch, *, url="https://health.example.com/healthkit/v1/ingest"):
    monkeypatch.setenv("HARU_HEALTHKIT_PROBE_URL", url)
    monkeypatch.setenv("HARU_HEALTHKIT_PROBE_TOKEN", "test-probe-token-xxxxxxxx")


def test_probe_rejects_plain_http_before_sending_credentials(monkeypatch):
    configure_probe(monkeypatch, url="http://health.example.com/healthkit/v1/ingest")

    def must_not_build_opener(*args, **kwargs):
        raise AssertionError("credentialed HTTP probe attempted network setup")

    monkeypatch.setattr(probe, "build_opener", must_not_build_opener)
    assert probe.main() == 2


@pytest.mark.parametrize(
    "redirect_url",
    [
        "http://health.example.com/healthkit/v1/ingest",
        "https://other.example.com/healthkit/v1/ingest",
    ],
)
def test_probe_redirect_handler_never_forwards_authorization(redirect_url):
    handler = probe.RejectRedirectHandler()
    original = Request(
        "https://health.example.com/healthkit/v1/ingest",
        headers={"Authorization": "Bearer secret"},
    )
    redirected = handler.redirect_request(
        original,
        None,
        302,
        "Found",
        {"Location": redirect_url},
        redirect_url,
    )
    assert redirected is None


@pytest.mark.parametrize(
    "response_payload",
    [
        ["not", "an", "object"],
        {"accepted": True, "duplicates": 0, "rejected": 0},
        {"accepted": 1, "duplicates": 0},
        {"accepted": 1, "duplicates": 0, "rejected": 1},
    ],
)
def test_probe_rejects_invalid_success_contract(monkeypatch, response_payload):
    configure_probe(monkeypatch)
    opener = FakeOpener(FakeResponse(response_payload))
    monkeypatch.setattr(probe, "build_opener", lambda *handlers: opener)
    assert probe.main() == 1


def test_probe_accepts_strict_zero_rejection_contract(monkeypatch):
    configure_probe(monkeypatch)
    opener = FakeOpener(FakeResponse({"accepted": 1, "duplicates": 0, "rejected": 0}))
    monkeypatch.setattr(probe, "build_opener", lambda *handlers: opener)
    assert probe.main() == 0
    request, timeout = opener.requests[0]
    assert request.full_url.startswith("https://")
    assert timeout == 15
