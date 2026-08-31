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
# It parses the entitlements via `plutil` (a real, structured plist operation)
# rather than a loose grep, so a value that merely *looks* like a key is not
# accepted. The extracted plist is written to the optional second argument
# (default: stdout path in a temp file) so CI can upload it as evidence.

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

check_key() {
  local key="$1"
  # NOTE: do NOT use `plutil -extract <key> raw` here — the "raw" output mode
  # only supports string/integer values and errors on booleans (our HealthKit
  # entitlements are booleans), which would falsely fail the gate.
  if plutil -extract "$key" "$TMP" >/dev/null 2>&1; then
    echo "  present: $key"
  else
    echo "Entitlements gate: FAIL - missing required entitlement '$key'" >&2
    exit 1
  fi
}

echo "Reading entitlements from $APP ..."
check_key "com.apple.developer.healthkit"
check_key "com.apple.developer.healthkit.background-delivery"

echo "Entitlements gate: PASS (healthkit + healthkit.background-delivery present)"
echo "  evidence: $TMP"
