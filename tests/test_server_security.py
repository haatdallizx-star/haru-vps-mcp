from haru_mcp.server import _transport_security
from haru_mcp.settings import load_settings


def test_transport_allowlist_is_loopback_only_by_default():
    security = _transport_security(load_settings(env={}))
    assert security.enable_dns_rebinding_protection is True
    assert "127.0.0.1:8765" in security.allowed_hosts
    assert security.allowed_origins == []


def test_configured_public_origin_only_extends_transport_allowlist():
    cfg = load_settings(env={
        "HARU_MCP_PUBLIC_HOST": "mcp.example.com",
        "HARU_MCP_PUBLIC_ORIGIN": "https://mcp.example.com",
    })
    security = _transport_security(cfg)
    assert "mcp.example.com" in security.allowed_hosts
    assert security.allowed_origins == ["https://mcp.example.com"]
    assert cfg.host == "127.0.0.1"
