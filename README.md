# Haru VPS MCP

**A mini tunnel to a mini computer for ChatGPT.**

**Setup guide:** [Notion-style web note (中文 / English)](https://kohaku4yz.github.io/haru-vps-mcp/)

Haru VPS MCP is a small self-hosted MCP gateway for an isolated VPS workspace. It gives an MCP client a narrow filesystem/shell facade without making the host itself the workspace.

```text
ChatGPT / MCP client
        |
 authenticated/private tunnel
        |
        v
 Haru MCP gateway
   127.0.0.1:8765
        |
   +----+----+
   |         |
   v         v
filesystem  shell
 backend    backend
 loopback   loopback
   |         |
   +----v----+
 isolated workspace
```

## Security boundary

Haru MCP exposes powerful workspace filesystem and shell tools, so treat the endpoint as privileged.

- The gateway refuses non-loopback bind addresses.
- Workspace backend URLs must be explicit loopback HTTP endpoints and cannot contain credentials.
- The backend itself gets no second public hostname; it stays behind the gateway on loopback.
- Optional public Host/Origin allowlists are request/transport hardening only. **They are not authentication.**
- `deploy/Caddyfile.example` fails closed with HTTP 403. Replace it only for a separately reviewed authenticated ingress design.
- For a private/on-prem/local MCP server used from ChatGPT, see [`docs/SECURE-TUNNEL.md`](docs/SECURE-TUNNEL.md) and the current OpenAI Secure MCP Tunnel documentation instead of binding Haru to `0.0.0.0`.
- Keep the delegated workspace disposable and separate from host configuration, credentials, home directories, and production data.

This public repository is a clean reference distribution, not a mirror of a private production host. It intentionally excludes private domains, machine identity, credentials, incident evidence, production deployment state, and owner-specific workspace contents.

## Quick start: gateway

Python 3.10+ is required.

```bash
python -m venv .venv
. .venv/bin/activate
pip install -e '.[test]'
pytest
./deploy/verify.sh
```

`deploy/haru-mcp.env.example` is a non-secret environment template. The gateway reads its process environment directly; it does **not** auto-load a `.env` file.

For a local foreground run, copy/edit the template and explicitly export it into the shell before starting Haru:

```bash
cp deploy/haru-mcp.env.example .env
# edit .env as needed
set -a
. ./.env
set +a
haru-mcp
```

For systemd, install the reviewed values into the `EnvironmentFile=` used by your service unit instead.

By default, the gateway listens at `127.0.0.1:8765/mcp` and delegates to:

```text
http://127.0.0.1:8766/servers/filesystem/mcp
http://127.0.0.1:8766/servers/shell/mcp
```

Those two endpoints are a **separate workspace-backend composition**. To build them from the selected upstream components, follow [`docs/WORKSPACE-BACKENDS.md`](docs/WORKSPACE-BACKENDS.md).

The public tool surface is deliberately small: gateway health, workspace directory listing/read/write/edit/move/stat, and isolated shell execution delegated to the loopback backends.

## Operator documentation

- [`docs/WORKSPACE-BACKENDS.md`](docs/WORKSPACE-BACKENDS.md) — build and operate the loopback filesystem/shell composition.
- [`docs/SECURE-TUNNEL.md`](docs/SECURE-TUNNEL.md) — server-side Secure MCP Tunnel boundary, service supervision, fail-closed recovery, and real-client acceptance.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — gateway service operations, layered health, upgrades/rollback, repository exact-head discipline, process hygiene, and secrets.
- [`deploy/haru-mcp.service.example`](deploy/haru-mcp.service.example) — minimal hardened systemd starting point.
- [`deploy/Caddyfile.example`](deploy/Caddyfile.example) — intentionally fail-closed public reverse-proxy example.

## Upstream projects

The gateway imports the MCP Python SDK, AnyIO, and typing-extensions. The optional reference workspace composes `mcp-proxy`, the Model Context Protocol filesystem server, and `shell-exec-mcp` without vendoring their source.

Exact selected workspace versions/commits, the `mcp==1.27.1` proxy-stack compatibility pin, and upstream license notes are recorded in [`THIRD-PARTY.md`](THIRD-PARTY.md).

## License

Haru VPS MCP code owned by this repository is available under the [MIT License](LICENSE).

Third-party components keep their own licenses; see [`THIRD-PARTY.md`](THIRD-PARTY.md).
