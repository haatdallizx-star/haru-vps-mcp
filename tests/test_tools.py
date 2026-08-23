import re

from haru_mcp.settings import load_settings
from haru_mcp import tools
from haru_mcp.tools import health


def test_health_is_small_static_snapshot():
    result = health()
    assert result["service"] == "haru-vps-mcp"
    assert result["status"] == "ok"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", result["timestamp_utc"])


async def test_chatgpt_file_import_delegates_to_bounded_child(monkeypatch):
    captured = {}

    async def fake_delegate(endpoint, tool_name, arguments, *, timeout_seconds):
        captured.update(
            endpoint=endpoint,
            tool_name=tool_name,
            arguments=arguments,
            timeout_seconds=timeout_seconds,
        )
        return "ok"

    monkeypatch.setattr(tools, "delegate_backend_tool", fake_delegate)
    cfg = load_settings(env={})
    result = await tools.workspace_import_chatgpt_file(
        cfg,
        {
            "download_url": "https://files.oaiusercontent.com/file.bin?sig=secret",
            "file_id": "file_123",
            "mime_type": "application/octet-stream",
            "file_name": "original.bin",
        },
        "inbox/copied.bin",
    )

    assert result == "ok"
    assert captured["endpoint"] == cfg.workspace_file_ingress_url
    assert captured["tool_name"] == "import_chatgpt_file"
    assert captured["arguments"]["destination"] == "inbox/copied.bin"
    assert captured["arguments"]["overwrite"] is False
    assert captured["timeout_seconds"] == 90.0
