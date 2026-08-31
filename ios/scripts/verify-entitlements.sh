#!/usr/bin/env bash
# Mandatory entitlement gate for the HealthBridge .ipa build.
#
# Usage: verify-entitlements.sh <path-to-.app> [output-entitlements-plist]
#
# Extracts the code-signing entitlements from the built app and FAILS (non-zero)
# unless BOTH of the following are present:
#   - com.apple.developer.healthkit
#   - com.apple.developer.healthkit.background-delivery
#
# The check is a structured plist->JSON parse (plutil + python3), not a loose
# grep, and it compares exact key membership. It intentionally does NOT use
# `plutil -extract <key> raw`, because the HealthKit entitlements are booleans
# and the "raw" output mode only supports string/integer values. The extracted
# entitlements are also echoed to the log as evidence.

set -euo pipefail

APP="${1:?usage: verify-entitlements.sh <path-to-.app> [output-entitlements-plist]}"
OUT="${2:-}"

if [[ ! -d "$APP" ]]; then
  echo "Entitlements gate: FAIL - app not found at $APP" >&2
  exit 1
fi

TMP="${OUT:-$(mktemp)}"
if [[ -z "$OUT" ]]; then
  trap 'rm -f "$TMP"' EXIT
fi

# `codesign -d --entitlements <file>` writes the app's embedded entitlements to
# <file>; it only succeeds if the app is actually signed.
if ! codesign -d --entitlements "$TMP" "$APP" >/dev/null 2>&1; then
  echo "Entitlements gate: FAIL - app is not signed (cannot read entitlements)." >&2
  echo "  An unsigned app (e.g. CODE_SIGNING_ALLOWED=NO left as final state) has no" >&2
  echo "  embedded entitlements. Ad-hoc sign with the entitlements before gating." >&2
  exit 1
fi

echo "Extracted entitlements from $APP:"
plutil -p "$TMP" || true
echo "---"

# Convert to JSON and parse with python3 - robust for boolean values.
JSON="$(plutil -convert json -o - "$TMP" 2>/dev/null || echo '{}')"
python3 - "$JSON" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
required = [
    "com.apple.developer.healthkit",
    "com.apple.developer.healthkit.background-delivery",
]
missing = [k for k in required if k not in data]
for k in sorted(data):
    print("  present: %s" % k)
if missing:
    print("Entitlements gate: FAIL - missing required entitlement(s): %s" % ", ".join(missing))
    sys.exit(1)
print("Entitlements gate: PASS (healthkit + healthkit.background-delivery present)")
PY
