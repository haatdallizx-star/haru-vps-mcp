"""Read-only, bounded HealthKit queries for the public MCP gateway."""
from __future__ import annotations

import sqlite3
import json
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_SAMPLE_TYPES = ("heart_rate", "hrv", "steps", "sleep", "menstrual_flow")
_ALLOWED_SAMPLE_TYPES = frozenset((*_SAMPLE_TYPES, "all"))
_ALLOWED_KINDS = frozenset({"status", "summary", "samples"})
_MAX_RANGE = timedelta(days=31)
_MAX_LIMIT = 200


def _connect_read_only(database_path: Path) -> sqlite3.Connection:
    uri = database_path.absolute().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("PRAGMA query_only=ON")
    return connection


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_timestamp(value: str, *, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError(f"{field} must be an ISO 8601 timestamp") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _window(start_at: str | None, end_at: str | None) -> tuple[str, str]:
    end = _parse_timestamp(end_at, field="end_at") if end_at else datetime.now(timezone.utc)
    start = _parse_timestamp(start_at, field="start_at") if start_at else end - timedelta(hours=24)
    if start >= end:
        raise ValueError("start_at must be earlier than end_at")
    if end - start > _MAX_RANGE:
        raise ValueError("query window must not exceed 31 days")
    return _utc_text(start), _utc_text(end)


def _status(database_path: Path) -> dict[str, Any]:
    counts = dict.fromkeys(_SAMPLE_TYPES[:-1], 0)
    with _connect_read_only(database_path) as connection:
        for row in connection.execute(
            "SELECT type, COUNT(*) AS count FROM healthkit_numeric_samples GROUP BY type"
        ):
            counts[row["type"]] = row["count"]
        counts["sleep"] = connection.execute(
            "SELECT COUNT(*) FROM healthkit_sleep_samples"
        ).fetchone()[0]
        if _has_menstrual(connection):
            counts["menstrual_flow"] = connection.execute("SELECT COUNT(*) FROM healthkit_menstrual_samples").fetchone()[0]
        last_sample_at = connection.execute(
            """
            SELECT MAX(end_at) FROM (
                SELECT end_at FROM healthkit_numeric_samples
                UNION ALL
                SELECT end_at FROM healthkit_sleep_samples
            )
            """
        ).fetchone()[0]
        if _has_menstrual(connection):
            menstrual_last = connection.execute("SELECT MAX(end_at) FROM healthkit_menstrual_samples").fetchone()[0]
            last_sample_at = max(filter(None, (last_sample_at, menstrual_last)), default=None)
        status = connection.execute(
            """
            SELECT last_ingest_at, last_successful_batch_at,
                   last_error_at, last_error_category
            FROM healthkit_ingest_status WHERE singleton = 1
            """
        ).fetchone()

    values = dict(status) if status is not None else {
        "last_ingest_at": None,
        "last_successful_batch_at": None,
        "last_error_at": None,
        "last_error_category": None,
    }
    return {
        "available": True,
        "kind": "status",
        "counts": counts,
        "total_samples": sum(counts.values()),
        "last_sample_at": last_sample_at,
        **values,
    }



def _has_menstrual(connection):
    return connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='healthkit_menstrual_samples'").fetchone() is not None


def _sleep_summary(rows, start_at, end_at):
    start = _parse_timestamp(start_at, field="start_at").timestamp()
    end = _parse_timestamp(end_at, field="end_at").timestamp()
    events = []
    for row in rows:
        a = max(start, _parse_timestamp(row["start_at"], field="start_at").timestamp())
        b = min(end, _parse_timestamp(row["end_at"], field="end_at").timestamp())
        if b > a:
            events.extend([(a, 1, row["stage"]), (b, -1, row["stage"])])
    active = Counter()
    stage_seconds = Counter()
    asleep_seconds = conflicts = 0.0
    previous = None
    asleep = {"core", "deep", "rem", "asleep"}
    for time, delta, stage in sorted(events):
        if previous is not None:
            duration = time - previous
            present = {key for key, count in active.items() if count > 0}
            for key in present:
                stage_seconds[key] += duration
            if present & asleep:
                asleep_seconds += duration
            if len(present & {"core", "deep", "rem"}) > 1 or ("awake" in present and present & asleep):
                conflicts += duration
        active[stage] += delta
        previous = time
    return {"count": len(rows), "total_hours": round(asleep_seconds / 3600, 6),
            "stages_hours": {key: round(seconds / 3600, 6) for key, seconds in sorted(stage_seconds.items()) if seconds > 0},
            "overlap_conflict_hours": round(conflicts / 3600, 6)}


def _summary(
    database_path: Path,
    *,
    sample_type: str,
    start_at: str,
    end_at: str,
) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    with _connect_read_only(database_path) as connection:
        numeric_params: list[Any] = [start_at, end_at]
        numeric_filter = ""
        if sample_type not in ("all", "sleep", "menstrual_flow"):
            numeric_filter = " AND type = ?"
            numeric_params.append(sample_type)
        if sample_type not in ("sleep", "menstrual_flow"):
            rows = connection.execute(
                """
                SELECT type, unit, COUNT(*) AS count, MIN(value) AS minimum,
                       MAX(value) AS maximum, AVG(value) AS average, SUM(value) AS total
                FROM healthkit_numeric_samples
                WHERE start_at >= ? AND start_at < ?
                """ + numeric_filter + " GROUP BY type, unit ORDER BY type",
                numeric_params,
            )
            for row in rows:
                if row["type"] == "steps":
                    metrics["steps"] = {
                        "count": row["count"],
                        "unit": row["unit"],
                        "total": float(row["total"]),
                    }
                else:
                    metrics[row["type"]] = {
                        "count": row["count"],
                        "unit": row["unit"],
                        "minimum": float(row["minimum"]),
                        "maximum": float(row["maximum"]),
                        "average": float(row["average"]),
                    }

        if sample_type in ("all", "sleep"):
            rows = list(connection.execute(
                "SELECT stage, start_at, end_at FROM healthkit_sleep_samples WHERE julianday(end_at)>julianday(?) AND julianday(start_at)<julianday(?)",
                (start_at, end_at)))
            metrics["sleep"] = _sleep_summary(rows, start_at, end_at)
        if sample_type in ("all", "menstrual_flow") and _has_menstrual(connection):
            rows = list(connection.execute(
                "SELECT flow, cycle_start FROM healthkit_menstrual_samples WHERE julianday(start_at)<julianday(?) AND (julianday(end_at)>julianday(?) OR (start_at=end_at AND julianday(start_at)>=julianday(?)))",
                (end_at, start_at, start_at)))
            metrics["menstrual_flow"] = {"count": len(rows),
                "flow_counts": dict(Counter(row["flow"] for row in rows)),
                "cycle_starts": sum(row["cycle_start"] == 1 for row in rows)}

    return {
        "available": True,
        "kind": "summary",
        "window": {"start_at": start_at, "end_at": end_at},
        "metrics": metrics,
    }


def _samples(
    database_path: Path,
    *,
    sample_type: str,
    start_at: str,
    end_at: str,
    limit: int,
) -> dict[str, Any]:
    clauses: list[str] = []
    parameters: list[Any] = []
    if sample_type not in ("sleep", "menstrual_flow"):
        type_clause = ""
        type_parameters: list[Any] = [start_at, end_at]
        if sample_type != "all":
            type_clause = " AND type = ?"
            type_parameters.append(sample_type)
        clauses.append(
            """SELECT type, value, unit, NULL AS stage, NULL AS flow, NULL AS cycle_start, NULL AS metadata_json, start_at, end_at
               FROM healthkit_numeric_samples
               WHERE start_at >= ? AND start_at < ?""" + type_clause
        )
        parameters.extend(type_parameters)
    if sample_type in ("all", "sleep"):
        clauses.append(
            """SELECT 'sleep' AS type, NULL AS value, NULL AS unit, stage, NULL AS flow, NULL AS cycle_start, NULL AS metadata_json, start_at, end_at
               FROM healthkit_sleep_samples
               WHERE julianday(end_at)>julianday(?) AND julianday(start_at)<julianday(?)"""
        )
        parameters.extend((start_at, end_at))

    with _connect_read_only(database_path) as connection:
        if sample_type in ("all", "menstrual_flow") and _has_menstrual(connection):
            clauses.append("""SELECT 'menstrual_flow' AS type, NULL AS value, NULL AS unit,
                NULL AS stage, flow, cycle_start, metadata_json, start_at, end_at
                FROM healthkit_menstrual_samples WHERE julianday(start_at)<julianday(?) AND
                (julianday(end_at)>julianday(?) OR (start_at=end_at AND julianday(start_at)>=julianday(?)))""")
            parameters.extend((end_at, start_at, start_at))
        sql = " UNION ALL ".join(clauses) + " ORDER BY end_at DESC LIMIT ?"
        parameters.append(limit)
        rows = list(connection.execute(sql, parameters)) if clauses else []

    samples: list[dict[str, Any]] = []
    for row in rows:
        sample = {
            "type": row["type"],
            "start_at": row["start_at"],
            "end_at": row["end_at"],
        }
        if row["type"] == "sleep":
            sample["stage"] = row["stage"]
        elif row["type"] == "menstrual_flow":
            sample["flow"] = row["flow"]
            sample["cycle_start"] = None if row["cycle_start"] is None else bool(row["cycle_start"])
            sample["timezone"] = json.loads(row["metadata_json"]).get("HKTimeZone")
        else:
            sample["value"] = float(row["value"])
            sample["unit"] = row["unit"]
        samples.append(sample)

    return {
        "available": True,
        "kind": "samples",
        "sample_type": sample_type,
        "window": {"start_at": start_at, "end_at": end_at},
        "samples": samples,
    }


def query_healthkit(
    database_path: Path | None,
    *,
    kind: str = "summary",
    sample_type: str = "all",
    start_at: str | None = None,
    end_at: str | None = None,
    limit: int = 50,
) -> dict[str, Any]:
    if database_path is None:
        return {"available": False, "error": "not_configured"}
    if kind not in _ALLOWED_KINDS:
        raise ValueError("kind must be one of: status, summary, samples")
    if sample_type not in _ALLOWED_SAMPLE_TYPES:
        raise ValueError("sample_type must be one of: all, heart_rate, hrv, steps, sleep, menstrual_flow")
    if not 1 <= limit <= _MAX_LIMIT:
        raise ValueError("limit must be between 1 and 200")

    try:
        if kind == "status":
            return _status(database_path)
        window_start, window_end = _window(start_at, end_at)
        if kind == "summary":
            return _summary(
                database_path,
                sample_type=sample_type,
                start_at=window_start,
                end_at=window_end,
            )
        return _samples(
            database_path,
            sample_type=sample_type,
            start_at=window_start,
            end_at=window_end,
            limit=limit,
        )
    except sqlite3.Error:
        return {"available": False, "error": "database_unavailable"}
