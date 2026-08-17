# Haru VPS MCP

**A mini tunnel to a mini computer for ChatGPT.**

Haru VPS MCP is a small self-hosted MCP gateway for an isolated VPS workspace. It gives an MCP client a narrow set of filesystem and shell capabilities without making the host itself the workspace.

```text
MCP client / authenticated tunnel
              |
              v
      Haru MCP gateway
        127.0.0.1:8765
              |
       +------+------+ 
       |             |
       v             v
 filesystem MCP   shell MCP
  loopback only   loopback only
       |             |
       +------v------+
       isolated workspace
```

## Public/private boundary

This repository is a clean public reference distribution, not a mirror of the author's private production environment. It intentionally excludes private domains, machine identity, credentials, incident evidence, production deployment state, adjacent personal services, and owner-specific workspace contents.

The reusable boundary is simple: the gateway and delegated workspace backends stay on loopback, while any remote access is provided by a separately authenticated tunnel or reverse proxy.

## Security model

Haru MCP exposes powerful workspace filesystem and shell tools, so treat the endpoint as privileged.

- The gateway refuses non-loopback bind addresses.
- Workspace backend URLs must be explicit loopback HTTP endpoints and cannot contain credentials.
- Optional public Host/Origin allowlists are transport hardening only. **They are not authentication.**
- `deploy/Caddyfile.example` fails closed with HTTP 403. Replace it only when your ingress layer actually authenticates clients.
- Do not expose the gateway or workspace backends anonymously on the Internet.
- Keep the delegated workspace disposable and separate from host configuration, credentials, home directories, and production data.

This first public extraction is a reference implementation. It preserves conservative boundaries from the private project, but it is not a claim that arbitrary deployments are production-safe without operator review.

## Install and test

Python 3.10+ is required.

```bash
python -m venv .venv
. .venv/bin/activate
pip install -e '.[test]'
pytest
```

You can also run the repository-local verification entry point:

```bash
./deploy/verify.sh
```

## Configure

Start from the example environment file:

```bash
cp deploy/haru-mcp.env.example .env
```

By default, the gateway listens at `127.0.0.1:8765/mcp` and delegates to two loopback MCP backend endpoints on port `8766`. Those backends should themselves be scoped to a dedicated workspace root.

If an authenticated reverse proxy or tunnel forwards a public hostname to the loopback gateway, set both:

```text
HARU_MCP_PUBLIC_HOST=mcp.example.com
HARU_MCP_PUBLIC_ORIGIN=https://mcp.example.com
```

These settings only extend Host/Origin validation. They do not add authentication.

## Run

```bash
haru-mcp
```

The public tool surface is deliberately small: gateway health, workspace directory listing/read/write/edit/move/stat, and isolated shell execution delegated to loopback MCP backends.

## Deployment examples

`deploy/haru-mcp.service.example` shows a hardened systemd service shape. `deploy/Caddyfile.example` is intentionally fail-closed until the operator supplies an authenticated ingress design.

## License

No license has been selected for this public repository yet. Licensing is an owner follow-up before a broader release.
