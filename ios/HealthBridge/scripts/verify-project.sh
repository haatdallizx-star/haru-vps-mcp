#!/usr/bin/env bash
set -euo pipefail

APP_PATH=${1:?usage: verify-project.sh /path/to/HealthBridge.app}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[[ -d "$APP_PATH" ]] || { echo "missing app: $APP_PATH" >&2; exit 1; }

entitlements=$(codesign -d --entitlements :- "$APP_PATH" 2>&1)
grep -q 'com.apple.developer.healthkit' <<<"$entitlements" || { echo "missing HealthKit entitlement" >&2; exit 1; }
grep -q 'com.apple.developer.healthkit.background-delivery' <<<"$entitlements" || { echo "missing HealthKit background-delivery entitlement" >&2; exit 1; }

plist="$APP_PATH/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :BGTaskSchedulerPermittedIdentifiers:0' "$plist" | grep -qx 'com.haru.healthbridge.refresh'
/usr/libexec/PlistBuddy -c 'Print :NSHealthShareUsageDescription' "$plist" >/dev/null

if grep -R --line-number --exclude='*.md' --exclude='verify-project.sh' -E 'HARU_HEALTHKIT_TOKEN[[:space:]]*=[[:space:]]*[^R$]' "$ROOT"; then
  echo "possible embedded ingest token found" >&2
  exit 1
fi

echo "healthbridge_entitlements=PASS"
echo "healthbridge_secret_scan=PASS"
