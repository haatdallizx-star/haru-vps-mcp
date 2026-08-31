#!/usr/bin/env bash
# Mandatory entitlement gate for the HealthBridge .ipa build.
#
# Usage: verify-entitlements.sh <path-to-.app> [output-entitlements.txt]
#
# Reads the code-signing entitlements from the built app and FAILS (non-zero)
# unless BOTH of the following are present in the signature:
#   - com.apple.developer.healthkit
#   - com.apple.developer.healthkit.background-delivery
#
# `codesign -d --entitlements - APP` is the authoritative source of what is in
# the signature; its display output lists each entitlement as a `[Key] <name>`
# line. We assert exact `[Key] <name>` tokens (not a substring match), which is
# robust and does not rely on plutil's boolean-value quirks.

set -euo pipefail

APP="${1:?usage: verify-entitlements.sh <path-to-.app> [output-entitlements.txt]}"
OUT="${2:-}"

if [[ ! -d "$APP" ]]; then
  echo "Entitlements gate: FAIL - app not found at $APP" >&2
  exit 1
fi

# codesign -d --entitlements - prints the entitlements (display format) to stdout.
# It returns nothing useful if the app is unsigned / has no entitlements.
DISP="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if [[ -z "$DISP" ]]; then
  echo "Entitlements gate: FAIL - app has no readable entitlements (unsigned?)." >&2
  echo "  An unsigned app (e.g. CODE_SIGNING_ALLOWED=NO as the final state) has no" >&2
  echo "  embedded entitlements. Ad-hoc sign it (codesign --sign - --entitlements ...) first." >&2
  exit 1
fi

echo "Entitlements in signature for $APP:"
printf '%s\n' "$DISP"

has_key() {
  # Match an exact `[Key] <name>` line; `-F` treats the pattern literally.
  printf '%s\n' "$DISP" | grep -qF "[Key] $1"
}

missing=()
for key in "com.apple.developer.healthkit" "com.apple.developer.healthkit.background-delivery"; do
  if has_key "$key"; then
    echo "  present: $key"
  else
    missing+=("$key")
  fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "Entitlements gate: FAIL - missing required entitlement(s): ${missing[*]}" >&2
  exit 1
fi

echo "Entitlements gate: PASS (healthkit + healthkit.background-delivery present)"

# Save an evidence copy of the entitlements display when an output path is given.
if [[ -n "$OUT" ]]; then
  printf '%s\n' "$DISP" > "$OUT"
  echo "  evidence written: $OUT"
fi
