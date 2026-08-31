# HealthKit VPS Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the isolated, authenticated VPS ingestion service that accepts HealthKit heart-rate, HRV, step, and sleep samples without modifying the existing shortcut health path.

**Architecture:** Add a small standalone ASGI service in this repository, bound to loopback and reverse-proxied over HTTPS at `/healthkit/v1/ingest`. It validates a bearer token and schema-v1 batches, stores samples idempotently in a dedicated SQLite database, records ingest health, and exposes no MCP write surface. This plan deliberately stops before the iOS app, patched xtool, Windows renewal script, and `healthkit_query`; those are independent subsystems and get their own plans after this server contract is green.

**Tech Stack:** Python 3.10+, Starlette, Uvicorn, stdlib `sqlite3`, pytest, httpx test client.

**Spec:** `docs/superpowers/specs/2026-08-31-healthkit-bridge-design.md`

## Global Constraints

- The existing shortcut-based health pipeline must remain operational and untouched.
- Phase 1 supports only `heart_rate`, `hrv`, `steps`, and `sleep`.
- Numeric canonical units are `bpm`, `ms`, and `count` respectively.
- Sleep remains interval/category data and must not be coerced to a scalar.
- HealthKit sample UUID is the idempotency key.
- All stored timestamps are normalized to UTC.
- Ingestion is HTTPS-only at the public proxy boundary; the Python service itself binds only to loopback.
- Bearer token is supplied by environment and never logged.
- Batch limit is 800 samples; unsupported schema versions and oversized batches are rejected.
- Only HTTP 2xx means the phone may delete an inflight batch.
- No proactive alerts and no old-data migration in this plan.

---

## File Structure

New package:

- `healthkit_ingest/__init__.py` — package marker/version-independent exports only.
- `healthkit_ingest/settings.py` — strict loopback host/port, database path, token, request limits.
- `healthkit_ingest/models.py` — schema-v1 parsing/normalization dataclasses and validation errors.
- `healthkit_ingest/store.py` — SQLite schema, transactions, UUID idempotency, ingest status.
- `healthkit_ingest/app.py` — Starlette routes, auth, body limits, response mapping.
- `healthkit_ingest/main.py` — Uvicorn entry point.

Tests:

- `tests/test_healthkit_settings.py`
- `tests/test_healthkit_models.py`
- `tests/test_healthkit_store.py`
- `tests/test_healthkit_api.py`

Deployment:

- `deploy/healthkit-ingest.env.example`
- `deploy/healthkit-ingest.service.example`
- modify `deploy/Caddyfile.example` only by adding an isolated `/healthkit/v1/ingest` reverse-proxy route.
- modify `deploy/verify-examples.py` so checked-in deployment examples remain mechanically validated.
- modify `pyproject.toml` to package `healthkit_ingest*`, add Starlette/Uvicorn runtime dependencies, httpx test dependency, and `healthkit-ingest` console script.

---

### Task 1: Strict HealthKit ingest settings and package entry point

**Files:**
- Create: `healthkit_ingest/__init__.py`
- Create: `healthkit_ingest/settings.py`
- Create: `tests/test_healthkit_settings.py`
- Modify: `pyproject.toml`

**Interfaces:**
- Produces: `HealthKitSettings`, `HealthKitSettingsError`, `load_healthkit_settings(env: Mapping[str, str] | None = None) -> HealthKitSettings`.
- Produces console entry point `healthkit-ingest = healthkit_ingest.main:main` (the target is implemented in Task 5; packaging may reference it before that file exists).

- [ ] **Step 1: Write failing settings tests**

Create `tests/test_healthkit_settings.py` with tests asserting:

```python
from pathlib import Path
import pytest

from healthkit_ingest.settings import HealthKitSettingsError, load_healthkit_settings


def base_env(tmp_path: Path) -> dict[str, str]:
    return {
        "HARU_HEALTHKIT_TOKEN": "test-secret-token",
        "HARU_HEALTHKIT_DB": str(tmp_path / "healthkit.sqlite3"),
    }


def test_defaults_are_loopback_and_isolated(tmp_path):
    cfg = load_healthkit_settings(env=base_env(tmp_path))
    assert cfg.host == "127.0.0.1"
    assert cfg.port == 8770
    assert cfg.database_path == tmp_path / "healthkit.sqlite3"
    assert cfg.max_batch_samples == 800
    assert cfg.max_body_bytes == 2_000_000


def test_token_is_required(tmp_path):
    env = base_env(tmp_path)
    del env["HARU_HEALTHKIT_TOKEN"]
    with pytest.raises(HealthKitSettingsError, match="HARU_HEALTHKIT_TOKEN"):
        load_healthkit_settings(env=env)


def test_non_loopback_bind_is_rejected(tmp_path):
    env = base_env(tmp_path) | {"HARU_HEALTHKIT_HOST": "0.0.0.0"}
    with pytest.raises(HealthKitSettingsError, match="loopback"):
        load_healthkit_settings(env=env)
```

Also cover invalid port, empty token, relative DB path, nonpositive limits, and token values shorter than 16 characters.

- [ ] **Step 2: Run the settings test and verify RED**

Run:

```bash
pytest tests/test_healthkit_settings.py -q
```

Expected: collection/import failure because `healthkit_ingest.settings` does not exist.

- [ ] **Step 3: Implement strict settings**

Implement a frozen dataclass:

```python
@dataclass(frozen=True)
class HealthKitSettings:
    host: str
    port: int
    database_path: Path
    bearer_token: str
    max_batch_samples: int
    max_body_bytes: int
```

Use defaults `127.0.0.1`, `8770`, `800`, and `2_000_000`. Require an absolute database path and a token of at least 16 characters. Accept only `127.0.0.1`, `localhost`, or `::1` as bind hosts. Never include the token in exception text or dataclass repr; declare the field with `repr=False`.

Update `pyproject.toml`:

```toml
dependencies = [
  "mcp>=1.27,<2",
  "anyio>=4,<5",
  "typing-extensions>=4.12,<5",
  "starlette>=0.47,<1",
  "uvicorn>=0.35,<1",
]

[project.optional-dependencies]
test = [
  "pytest>=8,<9",
  "pytest-asyncio>=0.23,<1",
  "httpx>=0.28,<1",
]

[project.scripts]
haru-mcp = "haru_mcp.server:main"
healthkit-ingest = "healthkit_ingest.main:main"

[tool.setuptools.packages.find]
where = ["."]
include = ["haru_mcp*", "healthkit_ingest*"]
```

- [ ] **Step 4: Run settings tests and the existing suite**

Run:

```bash
pytest tests/test_healthkit_settings.py -q
pytest -q
```

Expected: new settings tests PASS; existing tests remain PASS.

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml healthkit_ingest tests/test_healthkit_settings.py
git commit -m "feat: add HealthKit ingest settings"
```

---

### Task 2: Schema-v1 HealthKit sample validation and normalization

**Files:**
- Create: `healthkit_ingest/models.py`
- Create: `tests/test_healthkit_models.py`

**Interfaces:**
- Consumes: `max_batch_samples` from Task 1.
- Produces: `parse_batch(payload: object, *, max_batch_samples: int) -> IngestBatch`.
- Produces immutable `NumericSample`, `SleepSample`, and `IngestBatch` dataclasses.
- Produces `PayloadValidationError(code: str, message: str)` where `code` is safe to return to the client.

- [ ] **Step 1: Write failing model tests**

Cover these exact cases:

```python
def test_numeric_sample_is_normalized_to_utc(): ...
def test_sleep_stage_remains_interval_data(): ...
def test_only_phase_one_types_are_accepted(): ...
def test_numeric_type_requires_canonical_unit(): ...
def test_sleep_rejects_numeric_value_and_unit(): ...
def test_unknown_sleep_stage_is_preserved_as_raw_value(): ...
def test_uuid_must_be_nonempty_string(): ...
def test_end_must_not_precede_start(): ...
def test_naive_timestamp_is_rejected(): ...
def test_schema_version_must_equal_one(): ...
def test_batch_may_not_exceed_800_samples(): ...
def test_metadata_must_be_json_object_and_is_allowlisted(): ...
```

Use a representative numeric payload:

```python
{
    "uuid": "11111111-1111-1111-1111-111111111111",
    "type": "heart_rate",
    "value": 72.0,
    "unit": "bpm",
    "start_at": "2026-08-31T05:00:00+00:00",
    "end_at": "2026-08-31T05:00:05+00:00",
    "queued_at": "2026-08-31T05:00:10+00:00",
    "source_name": "Apple Watch",
    "source_bundle": "com.apple.health",
    "device": "Apple Watch",
    "metadata": {},
}
```

Use a representative sleep payload with `type: "sleep"`, `stage: "core"`, and no scalar `value`/`unit`.

- [ ] **Step 2: Run model tests and verify RED**

```bash
pytest tests/test_healthkit_models.py -q
```

Expected: import failure because `healthkit_ingest.models` does not exist.

- [ ] **Step 3: Implement parsing and normalization**

Implement explicit parsing rather than permissive `**payload` construction. Normalize aware timestamps with:

```python
dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
```

Canonical type/unit mapping:

```python
NUMERIC_UNITS = {
    "heart_rate": "bpm",
    "hrv": "ms",
    "steps": "count",
}
```

Allow only a small metadata key set initially, for example `{"HKWasUserEntered", "HKMetadataKeyHeartRateMotionContext"}`; silently omit other metadata keys rather than persisting arbitrary HealthKit metadata. Preserve unknown sleep stage text in `stage_raw` while mapping known values to stable `stage` names.

- [ ] **Step 4: Run model tests and full suite**

```bash
pytest tests/test_healthkit_models.py -q
pytest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add healthkit_ingest/models.py tests/test_healthkit_models.py
git commit -m "feat: validate HealthKit ingest batches"
```

---

### Task 3: Dedicated SQLite store with UUID idempotency and ingest health

**Files:**
- Create: `healthkit_ingest/store.py`
- Create: `tests/test_healthkit_store.py`

**Interfaces:**
- Consumes: `IngestBatch`, `NumericSample`, `SleepSample` from Task 2.
- Produces: `HealthKitStore(path: Path)`.
- Produces: `HealthKitStore.initialize() -> None`.
- Produces: `HealthKitStore.ingest(batch: IngestBatch, *, received_at: datetime) -> IngestResult`.
- Produces: `HealthKitStore.status() -> IngestStatus`.

- [ ] **Step 1: Write failing store tests**

Tests must prove:

```python
def test_initialize_creates_only_healthkit_tables(tmp_path): ...
def test_numeric_and_sleep_samples_are_stored_separately(tmp_path): ...
def test_replaying_same_uuid_is_idempotent(tmp_path): ...
def test_mixed_new_and_duplicate_batch_reports_counts(tmp_path): ...
def test_batch_is_atomic_on_database_error(tmp_path): ...
def test_received_at_is_server_time_not_client_time(tmp_path): ...
def test_status_tracks_last_successful_ingest(tmp_path): ...
```

Also assert the database does not reference or create any table name used by the existing shortcut path.

- [ ] **Step 2: Run store tests and verify RED**

```bash
pytest tests/test_healthkit_store.py -q
```

Expected: import failure because `healthkit_ingest.store` does not exist.

- [ ] **Step 3: Implement SQLite schema and transaction**

Create only these new tables:

```sql
CREATE TABLE IF NOT EXISTS healthkit_numeric_samples (
    uuid TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK(type IN ('heart_rate','hrv','steps')),
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    source_name TEXT,
    source_bundle TEXT,
    device TEXT,
    metadata_json TEXT NOT NULL,
    queued_at TEXT NOT NULL,
    received_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS healthkit_sleep_samples (
    uuid TEXT PRIMARY KEY,
    stage TEXT NOT NULL,
    stage_raw TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    source_name TEXT,
    source_bundle TEXT,
    device TEXT,
    metadata_json TEXT NOT NULL,
    queued_at TEXT NOT NULL,
    received_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS healthkit_ingest_status (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    last_ingest_at TEXT,
    last_successful_batch_at TEXT,
    last_error_at TEXT,
    last_error_category TEXT
);
```

Use one SQLite transaction per accepted HTTP batch. Insert with `ON CONFLICT(uuid) DO NOTHING`, count `cursor.rowcount` to distinguish accepted from duplicates, and update status only after the sample transaction succeeds. Enable WAL mode and foreign keys on each connection.

- [ ] **Step 4: Run store tests and full suite**

```bash
pytest tests/test_healthkit_store.py -q
pytest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add healthkit_ingest/store.py tests/test_healthkit_store.py
git commit -m "feat: add isolated HealthKit sample store"
```

---

### Task 4: Authenticated `/healthkit/v1/ingest` ASGI endpoint

**Files:**
- Create: `healthkit_ingest/app.py`
- Create: `tests/test_healthkit_api.py`

**Interfaces:**
- Consumes: `HealthKitSettings`, `parse_batch`, `HealthKitStore`.
- Produces: `build_app(settings: HealthKitSettings) -> Starlette`.
- HTTP contract: `POST /healthkit/v1/ingest` with `Authorization: Bearer <token>`.
- Successful JSON: `{"accepted": int, "duplicates": int, "rejected": 0}`.

- [ ] **Step 1: Write failing API tests**

Using `starlette.testclient.TestClient`, cover:

```python
def test_valid_batch_returns_200_and_counts(tmp_path): ...
def test_replay_returns_duplicate_count(tmp_path): ...
def test_missing_auth_is_401_without_body_processing(tmp_path): ...
def test_wrong_token_is_401(tmp_path): ...
def test_unsupported_schema_is_400(tmp_path): ...
def test_malformed_json_is_400(tmp_path): ...
def test_more_than_800_samples_is_413(tmp_path): ...
def test_body_over_configured_byte_limit_is_413(tmp_path): ...
def test_validation_error_does_not_write_partial_batch(tmp_path): ...
def test_response_never_contains_configured_token(tmp_path): ...
```

- [ ] **Step 2: Run API tests and verify RED**

```bash
pytest tests/test_healthkit_api.py -q
```

Expected: import failure because `healthkit_ingest.app` does not exist.

- [ ] **Step 3: Implement auth and ingestion route**

Use `secrets.compare_digest()` for bearer-token comparison. Check the `Content-Length` header when present, then enforce the real byte limit while reading the body. Authentication must happen before JSON decoding.

Map failures consistently:

```text
401  missing/invalid bearer token
400  malformed JSON or schema/sample validation error
413  byte limit or sample-count limit exceeded
500  unexpected storage failure
200  whole validated batch committed/idempotently replayed
```

Return client-safe error JSON such as:

```json
{"error": "invalid_payload", "message": "schema_version must be 1"}
```

Do not echo request bodies, metadata, or authorization headers in logs.

- [ ] **Step 4: Run API tests and full suite**

```bash
pytest tests/test_healthkit_api.py -q
pytest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add healthkit_ingest/app.py tests/test_healthkit_api.py
git commit -m "feat: add authenticated HealthKit ingest API"
```

---

### Task 5: Runnable service and deployment examples

**Files:**
- Create: `healthkit_ingest/main.py`
- Create: `deploy/healthkit-ingest.env.example`
- Create: `deploy/healthkit-ingest.service.example`
- Modify: `deploy/Caddyfile.example`
- Modify: `deploy/verify-examples.py`
- Test: `tests/test_healthkit_settings.py`
- Test: `tests/test_healthkit_api.py`

**Interfaces:**
- Consumes: `load_healthkit_settings()` and `build_app()`.
- Produces executable `healthkit-ingest` service bound to configured loopback host/port.
- Public route remains HTTPS at the reverse proxy; direct port 8770 is never public.

- [ ] **Step 1: Add failing deployment-example assertions**

Extend deployment verification so it requires:

```text
healthkit-ingest service binds 127.0.0.1:8770
EnvironmentFile points at a HealthKit-specific env file
Caddy proxies only /healthkit/v1/ingest to 127.0.0.1:8770
example token is an obvious placeholder, never a usable secret
DB example path is absolute and separate from existing health storage
```

Run:

```bash
python deploy/verify-examples.py
```

Expected: FAIL because the HealthKit examples do not exist yet.

- [ ] **Step 2: Implement the Uvicorn entry point**

`healthkit_ingest/main.py` should be intentionally small:

```python
def main() -> int:
    cfg = load_healthkit_settings()
    app = build_app(cfg)
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level="info")
    return 0
```

Do not pass the bearer token to Uvicorn logging configuration.

- [ ] **Step 3: Add deployment examples**

`deploy/healthkit-ingest.env.example` documents only:

```dotenv
HARU_HEALTHKIT_HOST=127.0.0.1
HARU_HEALTHKIT_PORT=8770
HARU_HEALTHKIT_DB=/var/lib/haru-healthkit/healthkit.sqlite3
HARU_HEALTHKIT_TOKEN=REPLACE_WITH_A_RANDOM_SECRET_AT_LEAST_32_CHARS
HARU_HEALTHKIT_MAX_BATCH_SAMPLES=800
HARU_HEALTHKIT_MAX_BODY_BYTES=2000000
```

The systemd example must use a dedicated writable state directory, restart on failure, and not alter `haru-mcp.service`. Add a narrowly scoped Caddy handler for `/healthkit/v1/ingest` before the existing MCP handler so the two routes cannot collide.

- [ ] **Step 4: Verify examples and run all tests**

```bash
python deploy/verify-examples.py
pytest -q
python -m compileall -q haru_mcp healthkit_ingest
```

Expected: all exit 0.

- [ ] **Step 5: Commit**

```bash
git add healthkit_ingest/main.py deploy pyproject.toml tests
git commit -m "feat: package HealthKit ingest service"
```

---

### Task 6: Synthetic end-to-end ingest probe and regression gate

**Files:**
- Create: `scripts/probe-healthkit-ingest.py`
- Modify: `README.md`
- Modify: `docs/OPERATIONS.md`

**Interfaces:**
- Consumes deployed HTTPS endpoint and bearer token from environment.
- Produces a non-sensitive probe that sends one synthetic sample with a random UUID and checks the response contract.

- [ ] **Step 1: Write the probe with no embedded endpoint or token**

The script reads:

```text
HARU_HEALTHKIT_PROBE_URL
HARU_HEALTHKIT_PROBE_TOKEN
```

It sends one synthetic `heart_rate` sample marked `source_name: "healthkit-probe"`, requires HTTP 200, and requires `accepted + duplicates == 1`. Use Python stdlib HTTP facilities so the probe adds no runtime dependency.

- [ ] **Step 2: Document safe deployment/rollback procedure**

README/operations documentation must state:

1. install updated package
2. create `/var/lib/haru-healthkit` with service-only permissions
3. create a real random bearer token outside git
4. install/start only `healthkit-ingest.service`
5. add/reload the Caddy route
6. run the synthetic probe
7. confirm existing `haru-mcp` health/tests remain good
8. rollback by removing only the new Caddy route/service; do not touch shortcut health data

- [ ] **Step 3: Run final verification**

```bash
pytest -q
python deploy/verify-examples.py
python -m compileall -q haru_mcp healthkit_ingest scripts/probe-healthkit-ingest.py
```

Expected: all exit 0.

- [ ] **Step 4: Review the branch diff for isolation**

Run:

```bash
git diff main...HEAD --stat
git diff main...HEAD -- haru_mcp/
```

Expected: no production changes under `haru_mcp/`; the existing MCP gateway is not required for ingest to function.

- [ ] **Step 5: Commit**

```bash
git add scripts/probe-healthkit-ingest.py README.md docs/OPERATIONS.md
git commit -m "docs: add HealthKit ingest operations probe"
```

---

## Plan Self-Review

- Spec coverage in this subsystem: isolated storage, bearer auth, schema versioning, 800-sample cap, UUID idempotency, UTC normalization, numeric/sleep separation, ingest timestamps/status, HTTPS proxy boundary, no old-path modification, synthetic verification and rollback are all assigned to concrete tasks.
- Intentionally deferred to separate plans: iOS HealthKit authorization/anchors/outbox/background delivery; macOS CI/IPA; pinned patched xtool CI; Windows/WSL one-click renewal; real-device 24–48h acceptance; MCP `healthkit_query` and HealthKit-consistent step aggregation.
- No task in this plan requires modifying the existing shortcut health implementation.
- Public API contract is fixed before iOS work begins, so the iOS plan can target a stable request/response schema.
