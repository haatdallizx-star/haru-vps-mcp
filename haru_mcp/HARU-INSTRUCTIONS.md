# Haru VPS MCP operator guidance

Use this gateway as a narrow bridge into an isolated VPS workspace. Treat the workspace filesystem and shell tools as privileged capabilities.

- Keep the Haru gateway and workspace backends bound to loopback.
- Put any Internet-facing ingress behind authentication supplied by your tunnel or reverse proxy.
- Do not treat Host, Origin, or DNS-rebinding checks as authentication.
- Keep the delegated workspace root disposable and separate from production application data, credentials, home directories, and host configuration.
- Prefer read-only inspection before mutation. Keep changes scoped to the isolated workspace unless the operator explicitly authorizes a wider boundary.
