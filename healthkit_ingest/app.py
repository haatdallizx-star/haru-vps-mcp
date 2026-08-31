"""Authenticated ASGI endpoint for isolated HealthKit ingestion."""
from __future__ import annotations

import ipaddress
import json
import secrets
import time
from collections import OrderedDict, deque
from datetime import datetime, timezone

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .models import PayloadValidationError, parse_batch
from .settings import HealthKitSettings
from .store import HealthKitStore


def _json_error(
    status_code: int,
    code: str,
    message: str,
    *,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        {"error": code, "message": message},
        status_code=status_code,
        headers=headers,
    )


class AuthFailureLimiter:
    """Bounded sliding-window limiter for bad bearer tokens."""

    def __init__(
        self,
        *,
        max_failures: int = 5,
        window_seconds: float = 60.0,
        max_sources: int = 1_024,
    ) -> None:
        self.max_failures = max_failures
        self.window_seconds = window_seconds
        self.max_sources = max_sources
        self._failures: OrderedDict[str, deque[float]] = OrderedDict()

    @property
    def tracked_source_count(self) -> int:
        return len(self._failures)

    def _prune_expired_sources(self, now: float) -> None:
        cutoff = now - self.window_seconds
        while self._failures:
            _, attempts = next(iter(self._failures.items()))
            if attempts and attempts[-1] > cutoff:
                break
            self._failures.popitem(last=False)

    def check_and_record_failure(self, *sources: str) -> bool:
        now = time.monotonic()
        cutoff = now - self.window_seconds
        self._prune_expired_sources(now)
        limited = False
        for source in dict.fromkeys(sources):
            attempts = self._failures.pop(source, deque())
            while attempts and attempts[0] <= cutoff:
                attempts.popleft()
            limited = limited or len(attempts) >= self.max_failures
            if len(attempts) < self.max_failures:
                attempts.append(now)
            self._failures[source] = attempts
        while len(self._failures) > self.max_sources:
            self._failures.popitem(last=False)
        return limited

    def clear(self, *sources: str) -> None:
        for source in dict.fromkeys(sources):
            self._failures.pop(source, None)


def _immediate_peer(request: Request) -> str:
    peer = request.client.host if request.client is not None else "unknown"
    try:
        return str(ipaddress.ip_address(peer))
    except ValueError:
        return peer


def _request_source(request: Request, *, peer: str) -> str:
    try:
        peer_ip = ipaddress.ip_address(peer)
    except ValueError:
        return peer
    if not peer_ip.is_loopback:
        return str(peer_ip)

    forwarded = request.headers.get("x-forwarded-for")
    if not forwarded or "," in forwarded:
        return str(peer_ip)
    try:
        return str(ipaddress.ip_address(forwarded.strip()))
    except ValueError:
        return str(peer_ip)


def _is_json_media_type(request: Request) -> bool:
    content_type = request.headers.get("content-type", "")
    media_type = content_type.split(";", 1)[0].strip().lower()
    return media_type == "application/json" or (
        media_type.startswith("application/") and media_type.endswith("+json")
    )


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant: {value}")


def _bounded_json_int(value: str) -> int:
    digits = value.lstrip("-")
    if len(digits) > 309:
        raise PayloadValidationError("invalid_value", "numeric sample value must be representable")
    return int(value)


def _decode_json(raw: bytes) -> object:
    try:
        return json.loads(
            raw,
            parse_constant=_reject_json_constant,
            parse_int=_bounded_json_int,
        )
    except RecursionError:
        raise PayloadValidationError(
            "malformed_json",
            "request body must be valid JSON",
        ) from None


def _authorized(request: Request, token: str) -> bool:
    header = request.headers.get("authorization")
    if not header or not header.startswith("Bearer "):
        return False
    supplied = header[7:]
    return bool(supplied) and secrets.compare_digest(supplied, token)


async def _read_limited_body(request: Request, *, max_body_bytes: int) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            declared = int(content_length)
        except ValueError:
            raise PayloadValidationError("invalid_content_length", "Content-Length must be an integer") from None
        if declared > max_body_bytes:
            raise PayloadValidationError("body_too_large", "request body exceeds configured byte limit")

    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > max_body_bytes:
            raise PayloadValidationError("body_too_large", "request body exceeds configured byte limit")
    return bytes(body)


def build_app(settings: HealthKitSettings) -> Starlette:
    store = HealthKitStore(settings.database_path)
    store.initialize()
    limiter = AuthFailureLimiter()

    def record_failure(category: str) -> None:
        try:
            store.record_failure(category=category, occurred_at=datetime.now(timezone.utc))
        except Exception:
            # Observability must never replace the client-safe primary response.
            pass

    async def ingest(request: Request) -> JSONResponse:
        peer = _immediate_peer(request)
        source = _request_source(request, peer=peer)
        source_key = f"source:{source}"
        peer_key = f"peer:{peer}"
        if _authorized(request, settings.bearer_token):
            limiter.clear(source_key)
        else:
            if limiter.check_and_record_failure(source_key, peer_key):
                return _json_error(
                    429,
                    "auth_rate_limited",
                    "too many failed authentication attempts",
                    headers={"Retry-After": "60"},
                )
            return _json_error(
                401,
                "unauthorized",
                "missing or invalid bearer token",
                headers={"WWW-Authenticate": "Bearer"},
            )

        if not _is_json_media_type(request):
            record_failure("validation_failure")
            return _json_error(
                415,
                "unsupported_media_type",
                "Content-Type must be application/json",
            )

        try:
            raw = await _read_limited_body(request, max_body_bytes=settings.max_body_bytes)
        except PayloadValidationError as exc:
            record_failure("validation_failure")
            status = 413 if exc.code == "body_too_large" else 400
            return _json_error(status, exc.code, exc.message)

        try:
            payload = _decode_json(raw)
        except PayloadValidationError as exc:
            record_failure("validation_failure")
            return _json_error(400, exc.code, exc.message)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            record_failure("validation_failure")
            return _json_error(400, "malformed_json", "request body must be valid JSON")

        try:
            batch = parse_batch(payload, max_batch_samples=settings.max_batch_samples)
        except PayloadValidationError as exc:
            record_failure("validation_failure")
            status = 413 if exc.code == "batch_too_large" else 400
            return _json_error(status, exc.code, exc.message)

        try:
            result = store.ingest(batch, received_at=datetime.now(timezone.utc))
        except Exception:
            record_failure("storage_failure")
            return _json_error(500, "storage_failure", "HealthKit batch could not be stored")

        return JSONResponse(
            {"accepted": result.accepted, "duplicates": result.duplicates, "rejected": 0},
            status_code=200,
        )

    app = Starlette(routes=[Route("/healthkit/v1/ingest", ingest, methods=["POST"])])
    app.state.healthkit_store = store
    app.state.auth_failure_limiter = limiter
    return app
