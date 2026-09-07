"""Read-only MCP server that exposes a single ``healthkit_query`` tool.

ChatGPT surface is deliberately tiny: one read-only tool, no writes or deletes.
The gateway (haru-vps-mcp) fronts this server on its own loopback endpoint and
delegates ``healthkit_query`` here, so ChatGPT only ever sees that one tool name.

This server is deployed as a separate, unprivileged unit running as the
``haru-healthkit`` account so it may read the mode-0700 SQLite store that the
workspace/``haru`` identity cannot. The tool itself never writes.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Mapping

from mcp.server.fastmcp import FastMCP

from .query import query_healthkit

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8772
DEFAULT_PATH = "/mcp"
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})

Kind = Literal["status", "summary", "samples"]
SampleType = Literal["all", "heart_rate", "hrv", "steps", "sleep", "menstrual_flow"]


class HealthKitMCPSettingsError(ValueError):
    """Raised when HealthKit MCP configuration is unsafe or invalid."""


@dataclass(frozen=True)
class HealthKitMCPSettings:
    host: str
    port: int
    path: str
    database_path: Path


def load_healthkit_mcp_settings(*, env: Mapping[str, str] | None = None) -> HealthKitMCPSettings:
    """Read strict, loopback-only settings for the HealthKit MCP server.

    The gateway path is intentionally static; only the database location is
    configurable and it must be absolute (a non-absolute value would be a
    relative-path bug that silently points at the wrong store).
    """
    raw_env = dict(os.environ if env is None else env)

    host = raw_env.get("HARU_HEALTHKIT_MCP_HOST", DEFAULT_HOST)
    if host not in _LOOPBACK_HOSTS:
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_MCP_HOST must be a loopback address")

    try:
        port = int(raw_env.get("HARU_HEALTHKIT_MCP_PORT", str(DEFAULT_PORT)))
    except ValueError:
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_MCP_PORT must be an integer") from None
    if not 1 <= port <= 65535:
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_MCP_PORT is out of range")

    path = raw_env.get("HARU_HEALTHKIT_MCP_PATH", DEFAULT_PATH)
    if not path.startswith("/") or (path.endswith("/") and path != "/") or "?" in path or "#" in path:
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_MCP_PATH must be an absolute path without query or fragment")

    database_raw = raw_env.get("HARU_HEALTHKIT_DB")
    if not database_raw:
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_DB is required")
    database_path = Path(database_raw)
    if not database_path.is_absolute():
        raise HealthKitMCPSettingsError("HARU_HEALTHKIT_DB must be an absolute path")

    return HealthKitMCPSettings(host=host, port=port, path=path, database_path=database_path)


def build_healthkit_mcp(cfg: HealthKitMCPSettings) -> FastMCP:
    """Build the HealthKit MCP server with exactly one read-only tool."""
    server = FastMCP(
        name="haru-healthkit",
        host=cfg.host,
        port=cfg.port,
        streamable_http_path=cfg.path,
        stateless_http=True,
        json_response=True,
        log_level="WARNING",
    )

    @server.tool(
        name="healthkit_query",
        description=(
            "Read bounded HealthKit data from the VPS store. "
            "Read-only: never writes or deletes. "
            "kind=status returns ingest freshness and per-type sample counts; "
            "kind=summary returns window aggregates (avg/min/max or steps total, "
            "sleep hours by stage and menstrual flow records); kind=samples returns the latest raw samples. "
            "sample_type selects one type or 'all'; start_at/end_at bound the window "
            "(max 31 days); limit caps returned rows. User-local time is resolved "
            "from the supplied timestamps."
        ),
    )
    def healthkit_query_tool(
        kind: Kind = "summary",
        sample_type: SampleType = "all",
        start_at: str | None = None,
        end_at: str | None = None,
        limit: int = 50,
    ) -> dict[str, Any]:
        try:
            return query_healthkit(
                cfg.database_path,
                kind=kind,
                sample_type=sample_type,
                start_at=start_at,
                end_at=end_at,
                limit=limit,
            )
        except ValueError as exc:
            return {"available": False, "error": str(exc)}
        except Exception:  # pragma: no cover - defensive; query already wraps sqlite errors
            return {"available": False, "error": "unexpected_error"}

    return server


def main() -> int:
    cfg = load_healthkit_mcp_settings()
    build_healthkit_mcp(cfg).run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
