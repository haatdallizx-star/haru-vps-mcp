# HealthBridge real-device acceptance

This gate starts only after simulator tests, the Python contract suite, the device build, and entitlement verification are green. Simulator success does not prove HealthKit background delivery.

## Setup

- Install the CI-built IPA without changing its bundle identifier.
- Confirm the installed app retains `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery`.
- Enter the HTTPS server root and bearer token once. Confirm the token is not present in UserDefaults or logs.
- Grant read access for heart rate, HRV, steps, and sleep. No write permission is requested.
- Keep the existing Shortcut health path enabled during the acceptance window.

## Foreground checks

1. `Test Connection` returns a successful server status response.
2. First `Sync Now` reads no more than the latest 24 hours when no anchor exists.
3. Heart rate is stored in bpm, HRV in ms, steps in count, and sleep as interval/stage records.
4. Repeating `Sync Now` does not duplicate UUID-backed samples.
5. The server receives device id, app version, queue depth, samples, deletion tombstones, and HealthKit statistics step snapshots.
6. Server status shows the current device and a recent successful batch.

## Durability and recovery

1. Disable network access, create/receive new HealthKit data, and confirm the local queue grows.
2. Re-enable network access and confirm the queue drains only after HTTP 2xx responses.
3. Terminate and relaunch the app while records are pending/inflight; confirm records recover and drain without loss.
4. Replay an already accepted batch and confirm the server reports duplicates rather than creating duplicate rows.
5. Delete/correct a HealthKit sample and confirm its UUID is delivered as a tombstone and the VPS marks the stored sample deleted.

## Background checks

Run for at least 24–48 hours with the phone used normally and periodically locked. Record sample timestamp, local queued timestamp, and VPS `received_at` for latency measurement.

- Heart rate: new samples eventually arrive without manually opening HealthBridge.
- HRV: new samples eventually arrive without manually opening HealthBridge.
- Sleep: completed sleep-stage intervals eventually arrive after Health updates them.
- Steps: accept OS-controlled cadence; do not require minute-level delivery. User-facing totals must come from the uploaded HealthKit statistics snapshot, not a naive sum of raw Watch/iPhone samples.
- BGAppRefresh is fallback only and must not be described as a precise timer.

## Weekly re-sign check

After re-sign/reinstall, verify server URL, Keychain token, SQLite queue, and HealthKit anchors survive. Run `Test Connection` and `Sync Now` again before considering the weekly install path safe.

## Pass condition

Phase 1 passes only when all checks above are observed on the real iPhone and the old Shortcut path remains healthy throughout the acceptance window. Only after that gate should the old path be considered for retirement and the separate read-only `healthkit_query` MCP integration begin.
