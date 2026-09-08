# Sleep and menstrual collection

This extends the existing HealthBridge → authenticated ingest → read-only MCP flow.
The owner requested Apple Health sleep and menstrual tracking data. No prediction,
notifications, symptom collection, or writes back to Apple Health are introduced.

## Contract

- Keep POST /healthkit/v1/ingest. Envelope schema 2 adds `deleted_samples` entries
  (`uuid`, `type`) and `menstrual_flow` samples (`flow`, optional boolean
  `cycle_start`). Schema 1 quantity/sleep batches remain supported. Schema 1
  deletion requests are rejected instead of silently acknowledged.
- Sleep samples use stage rather than numeric value/unit: awake, core, deep,
  rem, asleep (unspecified), in_bed; unknown values remain distinguishable.
- Menstrual flow: unspecified, none, light, medium, heavy, unknown. A missing
  cycle-start flag stays null, not false. Preserve allowed HKTimeZone metadata.
- Per-batch cap counts additions plus deletions together (800 operations).
- Deletion UUID tombstones prevent stale, out-of-order background retries from
  resurrecting deleted samples. Existing UUID deduplication remains global.
  Deletion changes are authenticated phone ingest operations; MCP stays read-only.
- SQLite migration expands the UUID registry and adds menstrual/tombstone tables
  transactionally. Existing records, status and identity are retained.

## Phone behavior

Request read permissions for all five supported types. First import includes
30 days of sleep and 90 days of menstrual records; quantity history remains
24 hours. Keep each category query's initial lower bound with its anchor so later
anchored queries use the same predicate. Persist deletion batches before advancing
anchors, including a read containing only deletions. Legacy queued batch files
without the added optional fields continue decoding.

## Queries

Use existing `healthkit_query` with `sample_type=sleep` or `menstrual_flow`.
Windows remain at most 31 days (read multiple windows for longer history).
Sleep intervals intersect the query window and are clipped to it. Each stage
is unioned; total_hours unions asleep stages and excludes in_bed/awake.
Different overlapping specific stages or awake/asleep conflicts are reported as
`overlap_conflict_hours`; stage totals may overlap when sources conflict and must
not be summed to derive total sleep. These are recorded stage data, not clinical
measurements or an attempt to reproduce Apple's private source-priority rules.
Menstrual summaries return record count, flow counts, and count of cycle-start
flags in the requested window. No inference of an end date from missing entries.
Raw menstrual records include recorded intervals, flow, cycle_start and timezone.

## Source restoration

The public main branch contained the iOS collector but not the deployed ingest
package or query implementation. This change brings the deployed server sources
and tests back into the same repository before extending them. The baseline
models/app/store matched the installed ingest release byte-for-byte; query and
MCP server matched their installed site-packages byte-for-byte. No secrets,
actual health records, database files or environment files are included.

## Rollout order

1. Require Python tests and iOS simulator/Release/entitlement CI gates to pass.
2. Owner merges PR manually. Update server first using the administrator who
   controls the existing VPS services. This Work connection cannot sudo.
3. Administrator backs up the SQLite database via SQLite backup and both installed
   code locations, stops healthkit-mcp and healthkit-ingest, installs ONLY this
   healthkit_ingest package into each service's existing import location, checks
   syntax/imports and migration, and restarts those two services. Preserve both
   services' existing users, environment, credentials, ports, database and proxy.
   Do not replace the live haru_mcp gateway from this repository: that deployment
   includes separate customizations. Its current string argument forwarding already
   supports the new sample_type. Do not restart unrelated services.
4. Verify existing sample counts persist and menstrual_flow is an accepted query
   type. Test synthetic ingest only against a temporary isolated test database,
   never insert fabricated health records in production.
5. Re-sign the successful IPA using the existing patched xtool and same Apple
   team/bundle ID; install over the phone app. Do not uninstall it. Allow new read
   permissions. Inspect Collection errors and queued counts before testing sleep
   and menstrual queries against the Health app.
6. Test a deleted/copied test record only if the owner chooses to create one in
   Apple Health. No automatic deletion of real health records for verification.

Rollback before phone update: stop both services and restore code + pre-migration
DB backup. After new phone uploads, do not restore an old DB and discard new data:
keep schema-2-capable ingest and stop/repair the affected service instead.

## Validation

Results and exact tested commits are recorded in the PR. The initial iOS CI run
contains test-only regressions intentionally failing on the old collector.
Physical-device HealthKit access and background scheduling require phone acceptance.
