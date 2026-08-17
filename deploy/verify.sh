#!/usr/bin/env bash
set -euo pipefail

python -m compileall -q haru_mcp tests
python - <<'PY'
from haru_mcp.settings import load_settings
cfg = load_settings(env={})
assert cfg.host == "127.0.0.1"
assert cfg.workspace_filesystem_url.startswith("http://127.0.0.1:")
assert cfg.workspace_shell_url.startswith("http://127.0.0.1:")
print("settings_loopback_default=PASS")
PY

if python -c 'import pytest, mcp' >/dev/null 2>&1; then
  python -m pytest
else
  echo "pytest_with_mcp=SKIP (install test dependencies with: pip install -e '[test]')"
fi
