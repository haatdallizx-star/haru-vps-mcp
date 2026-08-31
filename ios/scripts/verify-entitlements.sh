#!/usr/bin/env bash
# Mandatory entitlement gate for the HealthBridge .ipa build.
#
# Usage: verify-entitlements.sh <path-to-.app> [output-entitlements-plist]
#
# Reads the code-signing entitlements from the built app (via `codesign -d
# --entitlements -`) and FAILS (non-zero) unless BOTH of the following are
# present:
#   - com.apple.developer.healthkit
#   - com.apple.developer.healthkit.background-delivery
#
# The check is a structured plist -> JSON parse (plutil + python3), not a loose
# grep, and compares exact key membership. `plutil -extract <key> raw` is NOT
# used because those entitlements are booleans and "raw" only supports
# string/integer values.

set -euo pipefail

APP="${1:?usage: verify-entitlements.sh <path-to-.app> [output-entitlements-plist]}"
OUT="${2:-}"

if [[ ! -d "$APP" ]]; then
  echo "Entitlements gate: FAIL - app not found at $APP" >&2
  exit 1
fi

# `codesign -d --entitlements - APP` prints the embedded entitlements (a plist)
# to stdout. It returns nothing when the app is unsigned / has no entitlements.
XML="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if [[ -z "$XML" ]]; then
  echo "Entitlements gate: FAIL - app has no readable entitlements (unsigned?)." >&2
  echo "  An unsigned app (e.g. CODE_SIGNING_ALLOWED=NO as the final state) has no" >&2
  echo "  embedded entitlements. Ad-hoc sign it (Xcode or codesign --sign -) first." >&2
  exit 1
fi

echo "Extracted entitlements from $APP:"
printf '%s\n' "$XML"

# Convert the plist to JSON and assert exact key membership in python3.
JSON="$(printf '%s\n' "$XML" | plutil -convert json -o - - 2>/dev/null || echo '{}')"
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

# Save an evidence copy of the extracted entitlements when an output path is given.
if [[ -n "$OUT" ]]; then
  printf '%s\n' "$XML" > "$OUT"
  echo "  evidence written: $OUT"
fi
