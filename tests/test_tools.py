import re

from haru_mcp.tools import health


def test_health_is_small_static_snapshot():
    result = health()
    assert result["service"] == "haru-vps-mcp"
    assert result["status"] == "ok"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", result["timestamp_utc"])
