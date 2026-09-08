from pathlib import Path

import pytest

from healthkit_ingest.mcp_server import (
    HealthKitMCPSettingsError,
    build_healthkit_mcp,
    load_healthkit_mcp_settings,
)


def test_healthkit_mcp_settings_are_loopback_only_and_require_absolute_database():
    cfg = load_healthkit_mcp_settings(
        env={"HARU_HEALTHKIT_DB": "/var/lib/haru-healthkit/healthkit.sqlite3"}
    )
    assert cfg.host == "127.0.0.1"
    assert cfg.port == 8772
    assert cfg.path == "/mcp"
    assert cfg.database_path == Path("/var/lib/haru-healthkit/healthkit.sqlite3")

    with pytest.raises(HealthKitMCPSettingsError, match="loopback"):
        load_healthkit_mcp_settings(
            env={"HARU_HEALTHKIT_DB": "/tmp/health.sqlite3", "HARU_HEALTHKIT_MCP_HOST": "0.0.0.0"}
        )
    with pytest.raises(HealthKitMCPSettingsError, match="absolute"):
        load_healthkit_mcp_settings(env={"HARU_HEALTHKIT_DB": "relative.sqlite3"})


async def test_healthkit_mcp_exposes_only_the_bounded_query_tool(tmp_path):
    cfg = load_healthkit_mcp_settings(env={"HARU_HEALTHKIT_DB": str(tmp_path / "health.sqlite3")})

    tools = await build_healthkit_mcp(cfg).list_tools()
    assert [tool.name for tool in tools] == ["healthkit_query"]
    tool = tools[0]

    properties = tool.inputSchema["properties"]
    assert set(properties) == {"kind", "sample_type", "start_at", "end_at", "limit"}
    assert set(properties["kind"]["enum"]) == {"status", "summary", "samples"}
    assert set(properties["sample_type"]["enum"]) == {"all", "heart_rate", "hrv", "steps", "sleep", "menstrual_flow"}
    assert "sql" not in properties
    assert tool.description.startswith("Read bounded HealthKit data")
