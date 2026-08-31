# HealthKit Bridge Design

Date: 2026-08-31
Status: Approved design

## Goal

Build a new HealthKit ingestion path that works alongside the existing Apple Health shortcut path without modifying, migrating, or deleting the old path during phase 1.

The first release must continuously move four HealthKit data classes from iPhone to the VPS and expose them to ChatGPT through one read-only MCP query tool:

- heart rate
- heart rate variability (HRV)
- step count
- sleep stages

The system is considered successful only after the new path runs for 24–48 hours on the real iPhone/Apple Watch setup while the phone is locked and the bridge app is not being actively used, including recovery from temporary network loss.

## Non-goals for phase 1

- No migration or deletion of the existing shortcut-based health pipeline.
- No attempt to expose every HealthKit data type.
- No strict promise of minute-level real-time delivery. HealthKit delivery is event-driven but iOS controls scheduling and individual sample types may have frequency limits.
- No proactive Bark or other push alert integration yet.
- No phone-side health analytics beyond the minimum needed to encode HealthKit samples correctly.
- No phone-only signing refresh flow.

## Architecture

```text
Apple Watch
  -> iPhone HealthKit
  -> HealthBridge iOS app
  -> HTTPS POST /healthkit/v1/ingest
  -> isolated HealthKit storage on VPS
  -> read-only healthkit_query MCP tool
  -> ChatGPT
```

The existing shortcut-based health path remains operational and untouched during phase 1.

### Design principles

1. **Old path isolation.** The new bridge uses a separate ingest API and separate storage. The old health path is not modified to make the new one work.
2. **Phone is a transport layer, not an analytics layer.** The app observes, incrementally reads, persists, and uploads samples. Aggregation stays on the server/query side.
3. **At-least-once delivery with idempotent ingestion.** The phone may retry batches. The server treats HealthKit sample UUIDs as idempotency keys.
4. **Durability before progress.** A HealthKit query anchor is advanced only after newly read samples are durably written to the local outbox.
5. **Observable latency.** Store enough timestamps to measure sample time, phone queue time, and server receive time rather than relying on a claimed delivery interval.
6. **Small public tool surface.** ChatGPT receives one read-only `healthkit_query` tool rather than one tool per metric.

## iOS application structure

The app should keep responsibilities isolated:

```text
HealthBridge
|- HealthKitManager
|  |- authorization
|  |- observer registration
|  |- background delivery
|  `- anchored incremental reads
|- SampleEncoder
|  |- heart_rate
|  |- hrv
|  |- steps
|  `- sleep
|- AnchorStore
|  `- independent anchor per HealthKit type
|- Outbox
|  |- pending
|  `- inflight
|- Uploader
|  `- background URLSession
|- SecureConfig
|  `- server URL + Keychain token
`- App UI
   |- authorization status
   |- last successful upload
   |- pending count
   |- manual sync
   `- concise diagnostics
```

### HealthKit lifecycle

HealthKit observer queries must be registered during application launch so iOS can relaunch the app for HealthKit events without requiring the UI to be opened.

For each supported type:

1. Register an `HKObserverQuery`.
2. Enable HealthKit background delivery at the best supported frequency for that type.
3. When notified, run an `HKAnchoredObjectQuery` from the stored anchor.
4. Encode returned samples.
5. Persist samples into the outbox.
6. Persist the new anchor only after the samples are durably queued.
7. Trigger upload.

Each HealthKit type owns a separate anchor. On first use, when no anchor exists, only samples from the previous 24 hours are read. This prevents accidental import of the complete Health history during the first installation. Historical backfill is explicitly deferred.

### Manual sync

The UI includes a manual sync action even though normal operation is automatic. Manual sync is a diagnostic boundary: it lets us distinguish HealthKit/query failures from background wake failures and network/server failures.

## Local durability and retry model

Use a two-stage disk-backed outbox:

```text
new HealthKit samples
  -> pending
  -> batch moved atomically to inflight
  -> HTTP upload
       -> 2xx: delete inflight batch
       -> failure: return batch to pending
```

Requirements:

- Pending and inflight state survive app termination and device reboot.
- Moving a batch from pending to inflight must not silently lose records if the process dies.
- A failed or interrupted request is safe to retry.
- A practical first batch cap is 800 samples.
- Server idempotency makes duplicate retries harmless.
- Queue diagnostics must expose pending count and last upload result.

A Background `URLSession` is used for upload so iOS may continue or resume transfer independently of the foreground app lifetime.

## Secure configuration

The app is not built with the production bearer token embedded in source code or CI artifacts.

On first setup the user enters:

- HTTPS server endpoint
- bearer token

The token is stored in Keychain using an accessibility class suitable for background work after first device unlock, such as `kSecAttrAccessibleAfterFirstUnlock`.

Logs must not print bearer tokens or raw sensitive payloads.

## API design

### Endpoint

```http
POST /healthkit/v1/ingest
Authorization: Bearer <token>
Content-Type: application/json
```

### Request envelope

```json
{
  "schema_version": 1,
  "device_id": "stable-random-installation-id",
  "sent_at": "2026-08-31T05:00:00Z",
  "samples": []
}
```

`device_id` is a bridge-installation identifier, not an advertising or hardware identifier.

### Response

Successful ingestion returns HTTP 2xx and counts that make retries/debugging observable:

```json
{
  "accepted": 120,
  "duplicates": 3,
  "rejected": 0
}
```

A request is removed from the phone inflight queue only after a 2xx response.

### Authentication and transport

- HTTPS only.
- Bearer token validation occurs before body processing.
- Reject unsupported schema versions.
- Apply conservative request-size and batch-size limits.
- Rate limit repeated authentication failures.

## Data model

All transmitted timestamps use an unambiguous ISO-8601 representation and are normalized to UTC for storage. User-local calendar interpretation happens at query time, not during ingestion.

### Numeric HealthKit samples

Heart rate, HRV, and step samples use a common shape:

```text
HealthSample
- uuid             unique HealthKit sample UUID
- type             heart_rate | hrv | steps
- value            numeric value
- unit             canonical unit
- start_at          UTC timestamp
- end_at            UTC timestamp
- source_name       optional source display name
- source_bundle     optional source bundle identifier
- device            optional sanitized device description
- metadata          allow-listed JSON metadata only
- queued_at         phone timestamp when durably queued
- received_at       server timestamp
```

Canonical units for phase 1:

- heart rate: `bpm`
- HRV: `ms`
- steps: `count`

`uuid` is unique in isolated HealthKit storage and is the primary idempotency key.

### Sleep samples

Sleep is modeled separately because `HKCategorySample` represents intervals/stages rather than a scalar quantity:

```text
SleepSample
- uuid
- stage
- start_at
- end_at
- source_name
- source_bundle
- device
- metadata
- queued_at
- received_at
```

Preserve raw stage semantics such as awake, core, deep, REM, asleep, and other values Apple may provide. Do not reduce sleep on the phone to a single nightly duration. Server/query logic may later merge intervals into nights and compute duration, stage distribution, awakenings, and other summaries.

### Step-count caveat

Raw step samples are retained, but user-facing step totals must not be produced by blindly summing every raw sample across iPhone and Apple Watch sources. HealthKit can reconcile overlapping device sources. The query layer must use a HealthKit-consistent aggregation strategy or an explicitly defined source precedence rule before reporting totals.

## VPS storage and service boundary

Phase 1 creates isolated storage for the HealthKit bridge. It does not reuse the existing shortcut health tables.

The server component owns:

- bearer-token authentication
- schema validation
- sample normalization
- UUID idempotency
- durable writes
- ingestion timestamps
- ingest-health diagnostics

Track at least:

- `last_ingest_at`
- last successful batch timestamp
- last rejected/error timestamp and category

The first version exposes this status for diagnostics but does not send proactive alerts.

## MCP query surface

Expose one new read-only tool:

```text
healthkit_query
```

The tool should support the four phase-1 data classes through parameters rather than separate tool registrations. It should be able to represent requests such as:

- recent heart-rate samples or summary over a requested interval
- recent HRV samples or summary
- step totals for a requested local-day/range using the approved aggregation semantics
- sleep stages and summarized sleep for a requested night/range
- bridge ingestion health / last received time

The MCP layer must not expose write/delete operations for HealthKit data.

Time expressions such as "today" and "last night" are resolved using the caller/user timezone supplied to the query layer, rather than hard-coding UTC+8 into stored records.

## Build pipeline

### iOS build

A macOS GitHub Actions workflow builds the app without requiring a locally owned Mac:

```text
Swift source
  -> XcodeGen
  -> xcodebuild
  -> ad-hoc signed .app
  -> entitlement validation
  -> IPA artifact
```

The build must preserve entitlements. Do not replace ad-hoc signing with a fully unsigned build if doing so removes required entitlement metadata.

CI validates the produced binary contains the expected HealthKit entitlement set, including HealthKit background delivery where required.

### Patched xtool build

A separate Linux GitHub Actions workflow builds the patched xtool used for signing/installing from Windows/WSL.

Rules:

- Pin an explicit upstream xtool commit.
- Apply the HealthKit background-delivery entitlement patch against that commit.
- Fail CI if the patch no longer applies cleanly or the expected patched identifier is absent.
- Build a reusable artifact for the Windows/WSL install flow.
- Never auto-track upstream `main` for the signing tool.

The patch/signing path is considered the most brittle part of the system and must be treated as replaceable infrastructure, not app-domain logic.

## Windows/WSL installation and weekly re-sign

The iPhone remains connected normally to Windows. WSL reaches the Windows Apple Mobile Device/usbmuxd endpoint through the TCP bridge described by the validated setup.

The final user-facing renewal flow should be reduced to:

1. connect and unlock iPhone
2. run one script
3. script verifies prerequisites and device visibility
4. script locates the current IPA
5. script configures the usbmuxd socket environment
6. script calls patched xtool install/signing flow
7. script reports a human-readable result

The script should fail early with clear messages for common conditions such as:

- iPhone not visible
- Windows usbmuxd service unavailable
- WSL bridge unavailable
- IPA missing
- authentication expired
- certificate/provisioning problem

Free Personal Team signing expiry is accepted as an operational constraint. The old health pipeline stays available during initial validation, so a bridge-signing failure does not remove all health access.

## Real-world latency measurement

Do not claim a fixed real-time SLA.

For every sample retain enough timing data to derive:

```text
sample end/start time
-> phone queued_at
-> VPS received_at
```

Use these values during the 24–48 hour validation window to determine actual delivery behavior for each metric on the real device pair.

## Error handling

### HealthKit

- Authorization denied: show per-type authorization state where available and do not spin retries.
- Anchor decode/persistence failure: surface a diagnostic error and avoid silently replacing a valid anchor with a blank one.
- Unknown sleep category value: preserve a stable raw representation rather than dropping the record.

### Queue

- Disk write failure: do not advance anchor.
- App dies with inflight data: recover inflight to a retryable state on next launch.
- Queue corruption: quarantine unreadable records and expose a diagnostic rather than deleting the whole queue.

### Network/API

- Timeout/5xx/offline: retry later, preserving payload.
- 401/403: keep data queued, stop aggressive retry, clearly report authentication failure.
- 4xx validation failure: retain enough local diagnostics to identify the rejected batch; do not enter an infinite tight retry loop.
- Only 2xx marks a batch as delivered.

## Testing strategy

### Server unit/integration tests

- valid batch accepted
- duplicate UUID ignored/idempotent
- mixed accepted/duplicate counts correct
- invalid token rejected before ingestion
- unsupported schema version rejected
- malformed/oversized batches rejected safely
- timestamps normalized correctly
- sleep stage samples stored without scalar coercion
- existing shortcut health tests remain unchanged and green

### iOS unit tests where practical

- sample encoders produce canonical units and fields
- sleep category mapping
- first-run 24-hour predicate generation
- anchor persistence ordering
- queue pending/inflight transitions
- retry/recovery after simulated interruption
- secure configuration does not serialize token into ordinary settings/logs

### CI checks

- iOS build succeeds on macOS runner
- expected entitlements exist in final artifact
- patched xtool builds from pinned commit
- xtool patch self-check passes

### Real-device acceptance test

Run for 24–48 hours and verify all of the following:

1. foreground manual sync succeeds
2. heart rate arrives after the phone is locked and app is not foregrounded
3. HRV arrives through the same background path when HealthKit produces new samples
4. step data is ingested and query totals do not double-count overlapping device sources
5. sleep stage intervals arrive and can be reconstructed into a night
6. temporary offline state grows pending queue rather than losing data
7. restoring network drains the queue automatically
8. replaying a batch creates no duplicate rows
9. app/process restart preserves anchors and queued data
10. background relaunch registers observers correctly
11. `healthkit_query` can read all four data classes and ingest health
12. existing shortcut health path remains functional throughout the test
13. measured per-type latency is recorded and reviewed

## Deployment order

Implementation should proceed in this order to minimize unknowns:

1. isolated VPS schema + authenticated ingest endpoint
2. server tests and a synthetic ingest probe
3. iOS app skeleton + HealthKit authorization
4. foreground manual read/upload for four types
5. anchor persistence + disk outbox
6. background observers + background delivery + Background URLSession
7. macOS GitHub Actions build + entitlement validation
8. pinned patched-xtool CI build
9. Windows/WSL install and one-click re-sign script
10. real-device 24–48 hour acceptance run
11. read-only `healthkit_query` MCP integration
12. only after acceptance, decide whether/how to retire the old shortcut path

## Phase-1 completion criteria

Phase 1 is complete when, without opening the HealthBridge app, the locked iPhone can continue moving newly produced HealthKit data for heart rate, HRV, steps, and sleep to the isolated VPS store; interruptions recover without data loss or duplication; anchors survive relaunch; measured delivery latency is acceptable; ChatGPT can retrieve the new data through a single read-only tool; and the pre-existing shortcut path has not been disrupted.
