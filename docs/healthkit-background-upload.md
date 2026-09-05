# HealthBridge background upload repair — 2026-09-05

## Status

Prepared on `codex/healthkit-background-upload`, based on main
`690b8abf8bd6867024c0965cf98618b1883942b8`. This is a proposed iOS app update,
not a deployed change. The current phone app and VPS services are unchanged.

**Validation limitation:** this workspace has neither Swift nor Xcode. New XCTest
cases have been written but have not been compiled or executed. A first push of
the test-only commit was rejected by automatic approval review because external
GitHub publication needs explicit approval. No alternative publication route was
used. Simulator tests, Release build, embedded-entitlement verification and IPA
packaging remain gated on an authorized branch push and CI run. Do not install
or describe this as a verified build before those gates pass.

## Why this repair is needed

The existing stop-crash fix correctly replaced an invalid background-session
`dataTask(with:completionHandler:)` with a normal session. It made uploads usable,
but the transfers could not continue independently of the app process.

Two related reliability defects were present: `Outbox.enqueue` swallowed write
failures while `SyncEngine` advanced the HealthKit anchor, and observers reported
completion before asynchronous reads had persisted their results. The background
status also reported success without inspecting Apple's registration result.

## Behavior in this branch

- Every chunk must be durably saved before the anchor advances. A failed enqueue
  leaves the old anchor and shows a per-metric collection error. A failed anchor
  save does not advance its in-memory copy. Previously saved chunks may replay
  with the same sample UUIDs; the existing server deduplication contract applies.
- Unreadable/corrupt anchor files pause collection and remain intact. A transient
  read failure is retried before later reads/writes. This avoids overwriting an
  unavailable bookmark store with a fresh 24-hour import.
- Observer callbacks complete after query processing and durable writes settle,
  including failures; they do not wait for the network. Overlapping reads for a
  metric coalesce into a subsequent read using the newly committed anchor.
- Queue, anchor, upload-result and published-status mutations use the main queue.
- Background uploads use `uploadTask(with:fromFile:)` and a session delegate.
  The derived request-body file contains the JSON envelope, not the token.
  The original pending/inflight batch format and configured endpoint are retained.
- The system session is reconnected at launch. Its task inventory is reconciled
  before orphan inflight batches are requeued. Active task UUIDs survive in
  `taskDescription`; suspended tasks are resumed. Completions racing inventory
  do not create phantom active IDs.
- At most four batches are scheduled concurrently. Successful completion fills
  available slots; failure pauses automatic refilling until another observer,
  foreground, unlock or manual trigger. There is no immediate failed-batch loop.
- Transport errors retain the batch even if a response object contains HTTP 200.
  Existing HTTP 2xx acknowledgement semantics remain; rejected sample counts
  are shown rather than silently hidden.
- The app delegate forwards background-session events; the OS completion handler
  runs once after that event cycle has settled. Unmatched old finish callbacks
  cannot finish a later cycle.
- Foreground authorization and resync use SwiftUI `scenePhase`; no authorization
  prompt is started from a background launch. Authorization-request completion
  is not mislabeled as proof of HealthKit read permission.
- New queue/anchor/body files use protection available after first unlock. This
  does not change HealthKit's own protected-data access rules.

## Comparison with the user's reference “成果.md”

The reference is a roadmap, not a complete tested implementation for this app.

| Area | Previous implementation | This branch / remaining work |
|---|---|---|
| Watch → iPhone HealthKit → app → VPS → GPT | Already connected | Preserved |
| HealthKit observers + incremental reads | Present, early completion | Completion and overlap handling repaired |
| Durable pending/inflight outbox | Present, swallowed enqueue failures | Save failure blocks progress |
| Background URLSession | Removed to stop launch crash | File upload + delegate + reconciliation added |
| Background registration status | Assumed enabled | Actual per-type results required |
| Sleep stages | Not collected | Still a separate category-sample task |
| BGAppRefreshTask fallback | Not implemented | Deferred; cannot promise fixed timing |
| Server-side disconnection alert | Not established by this change | Requires separate design; no unsolicited notifications added |
| Patched xtool / install path | Existing workflow | Retained, no new signing-tool work |
| “Minute-level, lockscreen unaffected” | Not an iOS guarantee | Do not repeat as a guarantee |

This repair does not add historical backfill or HealthKit deletion propagation;
those remain separate server/collector contract work. It does not reset anchors,
clear existing queues, rotate credentials, change the bundle ID or restart VPS
services. Outbox retention helps retries; it is not a guarantee against every
storage failure or an indefinite substitute for a working, signed app.

## Test coverage added (execution pending)

`SyncReliabilityTests`: failed enqueue blocks anchor progress; transport failure
with HTTP 200 retains a batch; observer completion follows durable storage;
query failure completes and preserves anchor; overlapping reads use updated
anchors; failed registration is visible; one metric's success preserves another's
error; failed anchor writes preserve memory; corrupted anchor files are retained.

`BackgroundUploadTests`: reconcile before scheduling; active tasks not resubmitted;
orphan batches become file uploads with correct envelope and no stored token;
HTTP auth failure retains data without immediate retry; completion/inventory race;
body-file failure requeues; background completion is once per cycle; successful
uploads schedule remaining backlog.

The transport fake replaces the unavailable system daemon, not queue persistence:
these tests use actual temporary batch/body/anchor files. They cannot establish
real iOS background scheduling behavior.

## Next steps after approval

1. Push only `codex/healthkit-background-upload` to the user's existing fork
   `haatdallizx-star/haru-vps-mcp`; open a draft PR against main. The existing
   workflow is triggered by the PR's iOS changes. Do not merge main yet.
2. First run the test-only ancestor to record the original regressions if feasible;
   then run the completed branch tests. Report actual results, not inferred passes.
3. Require simulator tests, Release build and both embedded HealthKit entitlement
   checks to pass. Download the `HealthBridge-ipa` artifact from the successful run.
4. Re-sign/install over the existing app with the existing patched xtool and same
   Apple team/bundle identity. Do not uninstall first: that would remove queues.
5. On the phone, verify foreground sync, a backlog larger than four batches,
   airplane-mode retention and later recovery, background/lock-unlock behavior,
   and foreground relaunch while tasks are active. Use normal backgrounding or
   process termination in a development test for OS continuation: user force-quit
   has different iOS semantics and must not be advertised as supported.
6. Check VPS ingest freshness and UUID deduplication after reconnect. Do not claim
   a fixed delivery interval; HealthKit and URLSession are scheduled separately.

Apple references:
- https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
- https://developer.apple.com/documentation/healthkit/executing-observer-queries
