"""FastMCP Streamable HTTP gateway with loopback-first transport security."""
from __future__ import annotations

import logging
import sys
from importlib.resources import files

from mcp import types
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .settings import SERVICE_NAME, Settings, load_settings
from .tools import (
    HealthResult,
    OpenAIFileRef,
    health,
    shell_execute,
    workspace_edit_file,
    workspace_get_file_info,
    workspace_import_chatgpt_file,
    workspace_list_directory,
    workspace_move_file,
    workspace_read_text_file,
    workspace_write_file,
)

logger = logging.getLogger(__name__)
INSTRUCTIONS_RESOURCE = "HARU-INSTRUCTIONS.md"


def _load_instructions() -> str:
    text = files("haru_mcp").joinpath(INSTRUCTIONS_RESOURCE).read_text(encoding="utf-8").strip()
    if not text:
        raise RuntimeError("Haru MCP instructions resource is empty")
    return text


def _transport_security(cfg: Settings) -> TransportSecuritySettings:
    allowed_hosts = [f"127.0.0.1:{cfg.port}", f"localhost:{cfg.port}", f"[::1]:{cfg.port}"]
    allowed_origins: list[str] = []
    if cfg.public_host and cfg.public_origin:
        allowed_hosts.extend([cfg.public_host, f"{cfg.public_host}:443"])
        allowed_origins.append(cfg.public_origin)
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=allowed_hosts,
        allowed_origins=allowed_origins,
    )


def build_server(settings: Settings | None = None) -> FastMCP:
    cfg = settings if settings is not None else load_settings()
    server = FastMCP(
        name=SERVICE_NAME,
        instructions=_load_instructions(),
        host=cfg.host,
        port=cfg.port,
        streamable_http_path=cfg.path,
        stateless_http=True,
        json_response=True,
        log_level="WARNING",
        transport_security=_transport_security(cfg),
    )

    @server.tool(name="health", description="Return a static gateway health snapshot. Takes no arguments.")
    def health_tool() -> HealthResult:
        return health()

    @server.tool(name="workspace_list_directory")
    async def list_directory_tool(path: str) -> types.CallToolResult:
        return await workspace_list_directory(cfg, path)

    @server.tool(name="workspace_read_text_file")
    async def read_text_file_tool(path: str) -> types.CallToolResult:
        return await workspace_read_text_file(cfg, path)

    @server.tool(name="workspace_write_file")
    async def write_file_tool(path: str, content: str) -> types.CallToolResult:
        return await workspace_write_file(cfg, path, content)

    @server.tool(name="workspace_edit_file")
    async def edit_file_tool(path: str, edits: list[dict[str, str]]) -> types.CallToolResult:
        return await workspace_edit_file(cfg, path, edits)

    @server.tool(name="workspace_move_file")
    async def move_file_tool(source: str, destination: str) -> types.CallToolResult:
        return await workspace_move_file(cfg, source, destination)

    @server.tool(name="workspace_get_file_info")
    async def get_file_info_tool(path: str) -> types.CallToolResult:
        return await workspace_get_file_info(cfg, path)

    @server.tool(
        name="workspace_import_chatgpt_file",
        description=(
            "Import one file attached to or generated in the current ChatGPT conversation "
            "into the Haru workspace. Pass a relative destination path whose parent "
            "directory already exists. The ChatGPT host supplies the file reference "
            "automatically; do not construct download URLs manually."
        ),
        meta={"openai/fileParams": ["file"]},
    )
    async def import_chatgpt_file_tool(
        file: OpenAIFileRef,
        destination: str,
        overwrite: bool = False,
    ) -> types.CallToolResult:
        return await workspace_import_chatgpt_file(cfg, file, destination, overwrite)

    @server.tool(name="shell_execute")
    async def shell_execute_tool(command: str, timeout_ms: int = 5000) -> types.CallToolResult:
        return await shell_execute(cfg, command, timeout_ms)

    return server


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    cfg = load_settings()
    logger.info("event=startup category=starting")
    build_server(cfg).run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    sys.exit(main())
