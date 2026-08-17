import pytest

from haru_mcp.settings import SettingsError, load_settings


def test_defaults_are_loopback_only():
    cfg = load_settings(env={})
    assert cfg.host == "127.0.0.1"
    assert cfg.public_host is None
    assert cfg.public_origin is None
    assert cfg.workspace_filesystem_url.startswith("http://127.0.0.1:")
    assert cfg.workspace_shell_url.startswith("http://127.0.0.1:")


def test_gateway_refuses_non_loopback_bind():
    with pytest.raises(SettingsError, match="loopback"):
        load_settings(env={"HARU_MCP_HOST": "0.0.0.0"})


def test_workspace_backend_refuses_remote_or_credentialed_url():
    with pytest.raises(SettingsError, match="loopback"):
        load_settings(env={"HARU_MCP_WORKSPACE_SHELL_URL": "http://example.com:8766/servers/shell/mcp"})
    with pytest.raises(SettingsError, match="credentials"):
        load_settings(env={"HARU_MCP_WORKSPACE_SHELL_URL": "http://" + "user" + ":" + "pass@127.0.0.1:8766/servers/shell/mcp"})


def test_public_host_and_origin_must_be_paired_and_https():
    with pytest.raises(SettingsError, match="set together"):
        load_settings(env={"HARU_MCP_PUBLIC_HOST": "mcp.example.com"})
    with pytest.raises(SettingsError, match="https"):
        load_settings(env={
            "HARU_MCP_PUBLIC_HOST": "mcp.example.com",
            "HARU_MCP_PUBLIC_ORIGIN": "http://mcp.example.com",
        })


def test_public_origin_pair_is_accepted_but_does_not_change_bind():
    cfg = load_settings(env={
        "HARU_MCP_PUBLIC_HOST": "mcp.example.com",
        "HARU_MCP_PUBLIC_ORIGIN": "https://mcp.example.com",
    })
    assert cfg.host == "127.0.0.1"
    assert cfg.public_host == "mcp.example.com"
