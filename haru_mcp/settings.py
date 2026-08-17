"""Strict, loopback-first settings for the public Haru MCP gateway."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Final
from urllib.parse import urlsplit

SERVICE_NAME: Final[str] = "haru-vps-mcp"
DEFAULT_HOST: Final[str] = "127.0.0.1"
DEFAULT_PORT: Final[int] = 8765
DEFAULT_PATH: Final[str] = "/mcp"
DEFAULT_WORKSPACE_FILESYSTEM_URL: Final[str] = "http://127.0.0.1:8766/servers/filesystem/mcp"
DEFAULT_WORKSPACE_SHELL_URL: Final[str] = "http://127.0.0.1:8766/servers/shell/mcp"
_LOOPBACK_HOSTS: Final[frozenset[str]] = frozenset({"127.0.0.1", "localhost", "::1"})


class SettingsError(ValueError):
    """Raised when configuration would weaken a required boundary."""


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    path: str
    workspace_filesystem_url: str
    workspace_shell_url: str
    public_host: str | None = None
    public_origin: str | None = None


def _require_loopback_host(host: str, *, field: str) -> str:
    if host not in _LOOPBACK_HOSTS:
        raise SettingsError(f"{field} must be a loopback address")
    return host


def validate_loopback_http_url(url: str, *, field: str, required_path: str) -> str:
    try:
        parts = urlsplit(url)
        hostname = parts.hostname
        port = parts.port
    except ValueError:
        raise SettingsError(f"{field} contains a malformed host or port") from None
    if parts.scheme != "http":
        raise SettingsError(f"{field} must use http")
    if parts.username is not None or parts.password is not None:
        raise SettingsError(f"{field} must not contain credentials")
    if hostname not in _LOOPBACK_HOSTS:
        raise SettingsError(f"{field} host must be loopback")
    if port is None or not 1 <= port <= 65535:
        raise SettingsError(f"{field} must include a valid explicit port")
    if parts.path != required_path:
        raise SettingsError(f"{field} must use path {required_path}")
    if parts.query or parts.fragment:
        raise SettingsError(f"{field} must not contain query or fragment components")
    return url


def _public_transport(raw_env: dict[str, str]) -> tuple[str | None, str | None]:
    host = raw_env.get("HARU_MCP_PUBLIC_HOST") or None
    origin = raw_env.get("HARU_MCP_PUBLIC_ORIGIN") or None
    if (host is None) != (origin is None):
        raise SettingsError("HARU_MCP_PUBLIC_HOST and HARU_MCP_PUBLIC_ORIGIN must be set together")
    if host is None:
        return None, None
    if any(ch in host for ch in "/:@?#") or host.strip() != host or not host:
        raise SettingsError("HARU_MCP_PUBLIC_HOST must be a bare hostname")
    parts = urlsplit(origin)
    if parts.scheme != "https" or parts.hostname != host or parts.username or parts.password:
        raise SettingsError("HARU_MCP_PUBLIC_ORIGIN must be https://<HARU_MCP_PUBLIC_HOST>")
    if parts.port not in (None, 443) or parts.path not in ("", "/") or parts.query or parts.fragment:
        raise SettingsError("HARU_MCP_PUBLIC_ORIGIN must be an HTTPS origin without path, query, or fragment")
    return host, origin.rstrip("/")


def load_settings(*, env: dict[str, str] | None = None) -> Settings:
    raw_env = dict(os.environ if env is None else env)
    host = _require_loopback_host(raw_env.get("HARU_MCP_HOST", DEFAULT_HOST), field="HARU_MCP_HOST")
    try:
        port = int(raw_env.get("HARU_MCP_PORT", str(DEFAULT_PORT)))
    except ValueError:
        raise SettingsError("HARU_MCP_PORT must be an integer") from None
    if not 1 <= port <= 65535:
        raise SettingsError("HARU_MCP_PORT is out of range")

    path = raw_env.get("HARU_MCP_PATH", DEFAULT_PATH)
    if not path.startswith("/") or (path.endswith("/") and path != "/") or "?" in path or "#" in path:
        raise SettingsError("HARU_MCP_PATH must be an absolute path without trailing slash, query, or fragment")

    filesystem_url = validate_loopback_http_url(
        raw_env.get("HARU_MCP_WORKSPACE_FILESYSTEM_URL", DEFAULT_WORKSPACE_FILESYSTEM_URL),
        field="HARU_MCP_WORKSPACE_FILESYSTEM_URL",
        required_path="/servers/filesystem/mcp",
    )
    shell_url = validate_loopback_http_url(
        raw_env.get("HARU_MCP_WORKSPACE_SHELL_URL", DEFAULT_WORKSPACE_SHELL_URL),
        field="HARU_MCP_WORKSPACE_SHELL_URL",
        required_path="/servers/shell/mcp",
    )
    public_host, public_origin = _public_transport(raw_env)
    return Settings(host, port, path, filesystem_url, shell_url, public_host, public_origin)
