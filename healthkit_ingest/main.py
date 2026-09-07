"""Runnable entry point for the isolated HealthKit ingest service."""
from __future__ import annotations

import uvicorn

from .app import build_app
from .settings import load_healthkit_settings


def main() -> int:
    cfg = load_healthkit_settings()
    app = build_app(cfg)
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level="info", proxy_headers=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
