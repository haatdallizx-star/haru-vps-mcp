"""Authenticated ASGI endpoint for isolated HealthKit ingestion."""
from __future__ import annotations

import json
import secrets
from dataclasses import asdict
from datetime import datetime, timezone

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .models import PayloadValidationError, parse_batch
from .settings import HealthKitSettings
from .store import HealthKitStore


def _json_error(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"error": code, "message": message}, status_code=status_code)


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

    def record_error(category: str) -> None:
        store.record_error(category, occurred_at=datetime.now(timezone.utc))

    async def ingest(request: Request) -> JSONResponse:
        if not _authorized(request, settings.bearer_token):
            return _json_error(401, "unauthorized", "missing or invalid bearer token")

        try:
            raw = await _read_limited_body(request, max_body_bytes=settings.max_body_bytes)
        except PayloadValidationError as exc:
            record_error(exc.code)
            status = 413 if exc.code == "body_too_large" else 400
            return _json_error(status, exc.code, exc.message)

        try:
            payload = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            record_error("malformed_json")
            return _json_error(400, "malformed_json", "request body must be valid JSON")

        try:
            batch = parse_batch(payload, max_batch_samples=settings.max_batch_samples)
        except PayloadValidationError as exc:
            record_error(exc.code)
            status = 413 if exc.code == "batch_too_large" else 400
            return _json_error(status, exc.code, exc.message)

        try:
            result = store.ingest(batch, received_at=datetime.now(timezone.utc))
        except Exception:
            record_error("storage_failure")
            return _json_error(500, "storage_failure", "HealthKit batch could not be stored")

        return JSONResponse(
            {
                "accepted": result.accepted,
                "duplicates": result.duplicates,
                "deleted": result.deleted,
                "rejected": 0,
                "server_time": result.server_time,
            },
            status_code=200,
        )

    async def status(request: Request) -> JSONResponse:
        if not _authorized(request, settings.bearer_token):
            return _json_error(401, "unauthorized", "missing or invalid bearer token")
        current = asdict(store.status())
        current["devices"] = [asdict(device) for device in store.devices()]
        current["server_time"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        return JSONResponse(current, status_code=200)

    app = Starlette(
        routes=[
            Route("/healthkit/v1/ingest", ingest, methods=["POST"]),
            Route("/healthkit/v1/status", status, methods=["GET"]),
        ]
    )
    app.state.healthkit_store = store
    return app
