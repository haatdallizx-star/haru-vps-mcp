"""Generic gateway tools and thin delegation to isolated loopback MCP backends."""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any, Final

import anyio
from mcp import ClientSession, types
from mcp.client.streamable_http import streamablehttp_client
from typing_extensions import TypedDict

from . import __version__
from .settings import SERVICE_NAME, Settings

logger = logging.getLogger(__name__)
_BACKEND_CALL_TIMEOUT_SECONDS: Final[float] = 30.0


class HealthResult(TypedDict):
    service: str
    version: str
    status: str
    timestamp_utc: str


def health() -> HealthResult:
    return {
        "service": SERVICE_NAME,
        "version": __version__,
        "status": "ok",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def _backend_failure() -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text="Haru workspace backend unavailable")],
        isError=True,
    )


async def delegate_backend_tool(endpoint: str, tool_name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    try:
        with anyio.fail_after(_BACKEND_CALL_TIMEOUT_SECONDS):
            async with streamablehttp_client(endpoint) as (read, write, _):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    return await session.call_tool(tool_name, arguments)
    except Exception:
        logger.warning("event=workspace_backend category=unavailable tool=%s", tool_name)
        return _backend_failure()


async def workspace_list_directory(settings: Settings, path: str):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "list_directory", {"path": path})


async def workspace_read_text_file(settings: Settings, path: str):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "read_text_file", {"path": path})


async def workspace_write_file(settings: Settings, path: str, content: str):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "write_file", {"path": path, "content": content})


async def workspace_edit_file(settings: Settings, path: str, edits: list[dict[str, str]]):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "edit_file", {"path": path, "edits": edits})


async def workspace_move_file(settings: Settings, source: str, destination: str):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "move_file", {"source": source, "destination": destination})


async def workspace_get_file_info(settings: Settings, path: str):
    return await delegate_backend_tool(settings.workspace_filesystem_url, "get_file_info", {"path": path})


async def shell_execute(settings: Settings, command: str, timeout_ms: int = 5000):
    return await delegate_backend_tool(settings.workspace_shell_url, "execute", {"command": command, "timeout_ms": timeout_ms})
