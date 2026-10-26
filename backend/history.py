"""Thirty days of training and recovery for the quest generator.

The backend reads Hevy, Strava, and WHOOP once per quest day, reduces the
feeds to compact summaries, and adds them to the morning context. The
model gets facts it cannot work out alone: what was lifted, at what weight
and effort, what was run, how recovery moved, and what the week still
needs. `limit_problems` then rejects a plan that breaks the hard training
limits, whatever the model wrote.

No tokens, notes, workout names from Strava, or GPS traces leave this module.
"""

from __future__ import annotations

import re
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import integrations

HISTORY_DAYS = 30
CACHE_SECONDS = 15 * 60
LB_PER_KG = 2.20462
HEVY_HISTORY_PAGES = 20
WHOOP_PAGE_LIMIT = 25
WHOOP_MAX_PAGES = 6

# A run counts as a 10K or 5K within GPS rounding, like the app's 50 m tolerance.
TEN_K_MIN_METERS = 9_950
FIVE_K_MIN_METERS = 4_950

# Hard limits on heavy squat and deadlift work around the running.
HEAVY_SHARE_OF_E1RM = 0.80
HEAVY_REPS_MAX = 6
HEAVY_LOWER_MAX_PER_7_DAYS = 2
HEAVY_LOWER_MIN_DAYS_APART = 2
MAX_TEN_KS_PER_DAY = 2

HEAVY_LOWER_PATTERN = re.compile(r"squat|deadlift")
LOWER_PATTERN = re.compile(r"squat|deadlift|lunge|leg press|hip thrust|step up|leg curl|leg extension|calf|romanian|rdl|good morning")
RUN_TYPES = {"run", "trailrun", "virtualrun"}

_cache: dict[tuple[str, str], tuple[float, dict[str, Any]]] = {}
_cache_lock = threading.Lock()


# MARK: - Building


def build(context: dict[str, Any]) -> dict[str, Any]:
    """Training history for the context's quest day. Cached per day and time zone for 15 minutes."""
    player = context.get("player") or {}
    day = str(player.get("localDate") or "")
    tz = str(player.get("timezone") or "")
    key = (day, tz)
    with _cache_lock:
        cached = _cache.get(key)
        if cached and time.monotonic() - cached[0] < CACHE_SECONDS:
            return cached[1]
    zone = integrations.local_zone(tz)
    today = datetime.strptime(day, "%Y-%m-%d").date()
    start = datetime.combine(today - timedelta(days=HISTORY_DAYS), datetime.min.time(), zone)
    end = datetime.combine(today + timedelta(days=1), datetime.min.time(), zone)
    with ThreadPoolExecutor(max_workers=3) as pool:
        hevy = pool.submit(fetch_hevy, start)
        strava = pool.submit(fetch_strava, start, end)
        whoop = pool.submit(fetch_whoop, start, end)
        workouts, hevy_status = hevy.result()
        activities, strava_status = strava.result()
        whoop_raw, whoop_status = whoop.result()
    history = summarize(
        today=today,
        zone=zone,
        workouts=workouts,
        activities=activities,
        whoop=whoop_raw,
        goals=context.get("goals") or {},
        quest_days=context.get("recentDays") or [],
    )
    history["sources"] = {"hevy": hevy_status, "strava": strava_status, "whoop": whoop_status}
    with _cache_lock:
        _cache[key] = (time.monotonic(), history)
    return history


def fetch_hevy(start: datetime) -> tuple[list[dict[str, Any]], str]:
    key = integrations.hevy_api_key()
    if not key:
        return [], "not configured"
    workouts: list[dict[str, Any]] = []
    for page in range(1, HEVY_HISTORY_PAGES + 1):
        payload = integrations.hevy_get(f"{integrations.HEVY_API}/v1/workouts?page={page}&pageSize={integrations.HEVY_PAGE_SIZE}", key)
        if not isinstance(payload, dict) or not isinstance(payload.get("workouts"), list):
            return workouts, "ok" if page > 1 else "request failed"
        parsed = [workout for workout in (integrations.hevy_workout(item) for item in payload["workouts"] if isinstance(item, dict)) if workout]
        workouts.extend(workout for workout in parsed if not integrations.before(workout["start"], start))
        # Newest first: once a page reaches before the window, later pages are older still.
        if not parsed or any(integrations.before(workout["start"], start) for workout in parsed):
            break
        if page >= int(payload.get("page_count") or page):
            break
    return workouts, "ok"


def fetch_strava(start: datetime, end: datetime) -> tuple[list[dict[str, Any]], str]:
    if not integrations.configured("strava"):
        return [], "not configured"
    token = integrations.access_token("strava")
    if not token:
        return [], "token refresh failed"
    activities: list[dict[str, Any]] = []
    for page in range(1, 4):
        payload = integrations.get_json(
            f"{integrations.STRAVA_API}/athlete/activities?after={int(start.timestamp())}&before={int(end.timestamp())}&per_page=100&page={page}",
            token,
        )
        if not isinstance(payload, list):
            return activities, "ok" if page > 1 else "request failed"
        activities.extend(item for item in payload if isinstance(item, dict))
        if len(payload) < 100:
            break
    return activities, "ok"


def fetch_whoop(start: datetime, end: datetime) -> tuple[dict[str, list[dict[str, Any]]], str]:
    empty: dict[str, list[dict[str, Any]]] = {"cycles": [], "recoveries": [], "sleeps": []}
    if not integrations.configured("whoop"):
        return empty, "not configured"
    token = integrations.access_token("whoop")
    if not token:
        return empty, "token refresh failed"
    result = {
        "cycles": whoop_records(token, "/v2/cycle", start, end),
        "recoveries": whoop_records(token, "/v2/recovery", start, end),
        "sleeps": whoop_records(token, "/v2/activity/sleep", start, end),
    }
    if not any(result.values()):
        return result, "request failed or no data"
    return result, "ok"


def whoop_records(token: str, path: str, start: datetime, end: datetime) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    next_token = ""
    for _ in range(WHOOP_MAX_PAGES):
        query = {"start": start.isoformat(), "end": end.isoformat(), "limit": WHOOP_PAGE_LIMIT}
        if next_token:
            query["nextToken"] = next_token
        payload = integrations.get_json(f"{integrations.WHOOP_API}{path}?{urllib.parse.urlencode(query)}", token)
        if not isinstance(payload, dict):
            break
        records.extend(item for item in payload.get("records") or [] if isinstance(item, dict))
        next_token = str(payload.get("next_token") or "")
        if not next_token:
            break
    return records


# MARK: - Summaries (pure)


def summarize(
    today: date,
    zone: ZoneInfo,
    workouts: list[dict[str, Any]],
    activities: list[dict[str, Any]],
    whoop: dict[str, list[dict[str, Any]]],
    goals: dict[str, Any],
    quest_days: list[dict[str, Any]],
) -> dict[str, Any]:
    lifts = lift_summaries(workouts, today, zone)
    sessions = lift_sessions(workouts, lifts, today, zone)
    runs = run_list(activities, today, zone)
    recovery = recovery_days(whoop, zone)
    return {
        "windowDays": HISTORY_DAYS,
        "today": today.isoformat(),
        "weekday": today.strftime("%A"),
        "strengthSessions": sessions,
        "lifts": lifts,
        "strengthTargets": strength_targets(goals.get("strength") or [], lifts),
        "runs": runs,
        "recovery": recovery,
        "week": week_summary(today, runs, sessions, quest_days, int(goals.get("weeklyTenKs") or 5)),
        "limits": {
            "heavyLowerMaxPer7Days": HEAVY_LOWER_MAX_PER_7_DAYS,
            "heavyLowerMinDaysApart": HEAVY_LOWER_MIN_DAYS_APART,
            "heavyMeans": f"squat or deadlift work set at {int(HEAVY_SHARE_OF_E1RM * 100)}%+ of the lift's best 30-day e1RM, or {HEAVY_REPS_MAX} reps or fewer",
            "maxTenKsPerDay": MAX_TEN_KS_PER_DAY,
            "heavyLowerDates": [item["date"] for item in sessions if item["heavyLower"]],
        },
    }


def base_name(title: str) -> str:
    """`Squat (Barbell)` → `squat`, the name the app's Hevy check compares."""
    name = title.strip()
    if name.endswith(")") and "(" in name:
        name = name[: name.rfind("(")]
    return name.strip().lower()


def local_day(value: str, zone: ZoneInfo) -> date | None:
    moment = integrations.parse_utc(integrations.iso_utc(value)) if value else None
    return moment.astimezone(zone).date() if moment else None


def e1rm(kg: float, reps: int) -> float:
    """Epley, like the app: weight × (1 + reps / 30). One rep returns the weight."""
    return kg if reps <= 1 else kg * (1 + reps / 30)


def working_sets(exercise: dict[str, Any]) -> list[dict[str, Any]]:
    return [entry for entry in exercise.get("sets") or [] if str(entry.get("type") or "normal").lower() != "warmup"]


def lift_summaries(workouts: list[dict[str, Any]], today: date, zone: ZoneInfo) -> dict[str, dict[str, Any]]:
    """Per exercise: each session's working sets, top set, and e1RM, newest first, plus the 30-day best."""
    lifts: dict[str, dict[str, Any]] = {}
    for workout in sorted(workouts, key=lambda item: item["start"]):
        day = local_day(workout["start"], zone)
        if day is None:
            continue
        for exercise in workout.get("exercises") or []:
            name = base_name(str(exercise.get("title") or ""))
            sets = working_sets(exercise)
            if not name or not sets:
                continue
            entry = lifts.setdefault(name, {"exercise": name, "hevyTitle": exercise.get("title"), "sessions": []})
            weighted = [item for item in sets if (item.get("weightKg") or 0) > 0 and (item.get("reps") or 0) > 0]
            top = max(weighted, key=lambda item: e1rm(item["weightKg"], item["reps"]), default=None)
            entry["sessions"].append(
                {
                    "date": day.isoformat(),
                    "sets": [set_text(item) for item in sets],
                    "topSet": set_text(top) if top else None,
                    "e1rmKg": round(e1rm(top["weightKg"], top["reps"]), 1) if top else None,
                    "e1rmLb": round(e1rm(top["weightKg"], top["reps"]) * LB_PER_KG) if top else None,
                    "bestReps": max((item.get("reps") or 0 for item in sets), default=0),
                    "totalReps": sum(item.get("reps") or 0 for item in sets),
                    "seconds": sum(item.get("durationSec") or 0 for item in sets) or None,
                }
            )
    for entry in lifts.values():
        entry["sessions"].reverse()
        values = [item["e1rmKg"] for item in entry["sessions"] if item["e1rmKg"]]
        entry["bestE1rmKg"] = max(values) if values else None
        entry["bestE1rmLb"] = round(max(values) * LB_PER_KG) if values else None
        entry["lastDate"] = entry["sessions"][0]["date"]
        entry["daysSinceLast"] = (today - date.fromisoformat(entry["lastDate"])).days
        entry["sessionCount"] = len(entry["sessions"])
        entry["lowerBody"] = bool(LOWER_PATTERN.search(entry["exercise"]))
        if len(values) >= 2:
            entry["e1rmChangeKg"] = round(values[0] - values[-1], 1)
    return lifts


def set_text(entry: dict[str, Any]) -> str:
    """`100kg (220lb) x5 @8`, `x12`, or `60s`. Short enough for 30 days of sets."""
    parts = []
    kg = entry.get("weightKg")
    if kg:
        parts.append(f"{kg:g}kg ({round(kg * LB_PER_KG)}lb)")
    if entry.get("reps"):
        parts.append(f"x{entry['reps']}")
    if entry.get("durationSec") and not entry.get("reps"):
        parts.append(f"{int(entry['durationSec'])}s")
    if entry.get("rpe"):
        parts.append(f"@{entry['rpe']:g}")
    return " ".join(parts) or "logged"


def is_heavy_set(name: str, entry: dict[str, Any], best_kg: float | None) -> bool:
    if not HEAVY_LOWER_PATTERN.search(name):
        return False
    kg = entry.get("weightKg") or 0
    reps = entry.get("reps") or 0
    if kg <= 0 or reps <= 0:
        return False
    if best_kg and kg >= HEAVY_SHARE_OF_E1RM * best_kg:
        return True
    return reps <= HEAVY_REPS_MAX


def lift_sessions(workouts: list[dict[str, Any]], lifts: dict[str, dict[str, Any]], today: date, zone: ZoneInfo) -> list[dict[str, Any]]:
    """One row per Hevy workout, newest first, marked when it held heavy squat or deadlift work."""
    rows = []
    for workout in sorted(workouts, key=lambda item: item["start"], reverse=True):
        day = local_day(workout["start"], zone)
        if day is None:
            continue
        names = []
        heavy = False
        for exercise in workout.get("exercises") or []:
            name = base_name(str(exercise.get("title") or ""))
            if not name:
                continue
            names.append(name)
            best = (lifts.get(name) or {}).get("bestE1rmKg")
            heavy = heavy or any(is_heavy_set(name, entry, best) for entry in working_sets(exercise))
        start = integrations.parse_utc(workout["start"])
        end = integrations.parse_utc(workout["end"])
        rows.append(
            {
                "date": day.isoformat(),
                "daysAgo": (today - day).days,
                "exercises": names,
                "minutes": round((end - start).total_seconds() / 60) if start and end else None,
                "lowerBody": any(LOWER_PATTERN.search(name) for name in names),
                "heavyLower": heavy,
            }
        )
    return rows


def run_list(activities: list[dict[str, Any]], today: date, zone: ZoneInfo) -> list[dict[str, Any]]:
    """Every Strava activity in the window, newest first. Runs get pace and a 5K or 10K label."""
    rows = []
    for item in activities:
        day = local_day(str(item.get("start_date") or ""), zone)
        if day is None:
            continue
        sport = str(item.get("sport_type") or item.get("type") or "other")
        meters = float(item.get("distance") or 0)
        moving = float(item.get("moving_time") or 0)
        row: dict[str, Any] = {
            "date": day.isoformat(),
            "daysAgo": (today - day).days,
            "type": sport,
            "km": round(meters / 1000, 2),
            "movingMin": round(moving / 60, 1),
        }
        is_run = sport.lower() in RUN_TYPES
        if is_run and meters > 0 and moving > 0:
            pace = moving / (meters / 1000)
            row["pacePerKm"] = f"{int(pace // 60)}:{int(pace % 60):02d}"
        if is_run:
            row["counts"] = "10K" if meters >= TEN_K_MIN_METERS else "5K" if meters >= FIVE_K_MIN_METERS else "short"
        for source, target in (("average_heartrate", "avgHr"), ("max_heartrate", "maxHr"), ("total_elevation_gain", "elevationM"), ("suffer_score", "relativeEffort")):
            if isinstance(item.get(source), (int, float)):
                row[target] = round(float(item[source]))
        rows.append(row)
    rows.sort(key=lambda row: row["date"], reverse=True)
    return rows


def recovery_days(whoop: dict[str, list[dict[str, Any]]], zone: ZoneInfo) -> list[dict[str, Any]]:
    """One row per WHOOP cycle, newest first: recovery, HRV, resting HR, sleep, and the day's strain."""
    days: dict[int, dict[str, Any]] = {}
    for cycle in whoop.get("cycles") or []:
        day = local_day(str(cycle.get("start") or ""), zone)
        if day is None or not isinstance(cycle.get("id"), (int, str)):
            continue
        score = cycle.get("score") or {}
        days[cycle["id"]] = {"date": day.isoformat(), "strain": rounded(score.get("strain"), 1)}
    for recovery in whoop.get("recoveries") or []:
        row = days.get(recovery.get("cycle_id"))
        score = recovery.get("score") or {}
        if row is not None and isinstance(score, dict):
            row.update(
                {
                    "recovery": rounded(score.get("recovery_score")),
                    "hrv": rounded(score.get("hrv_rmssd_milli"), 1),
                    "restingHr": rounded(score.get("resting_heart_rate")),
                }
            )
    for sleep in whoop.get("sleeps") or []:
        if sleep.get("nap"):
            continue
        row = days.get(sleep.get("cycle_id"))
        score = sleep.get("score") or {}
        if row is None or not isinstance(score, dict):
            continue
        stages = score.get("stage_summary") or {}
        asleep = (stages.get("total_in_bed_time_milli") or 0) - (stages.get("total_awake_time_milli") or 0)
        row.update(
            {
                "sleepPerformance": rounded(score.get("sleep_performance_percentage")),
                "sleepHours": round(asleep / 3_600_000, 1) if asleep > 0 else None,
                "sleepEfficiency": rounded(score.get("sleep_efficiency_percentage")),
            }
        )
    rows = [{key: value for key, value in row.items() if value is not None} for row in days.values()]
    rows.sort(key=lambda row: row["date"], reverse=True)
    return rows


def rounded(value: Any, digits: int = 0) -> float | int | None:
    if not isinstance(value, (int, float)):
        return None
    return round(float(value), digits) if digits else round(float(value))


def strength_targets(targets: list[dict[str, Any]], lifts: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Each STR target the player kept, with the best matching lift in the window and the gap left."""
    rows = []
    for target in targets:
        aliases = {str(alias).lower() for alias in target.get("aliases") or []}
        matches = [entry for name, entry in lifts.items() if name.replace("-", " ") in aliases]
        row = {key: target[key] for key in ("category", "goal", "targetLb", "targetReps", "unit") if key in target}
        best = max((entry["bestE1rmLb"] or 0 for entry in matches), default=0)
        reps = max((session["bestReps"] for entry in matches for session in entry["sessions"]), default=0)
        if matches:
            row["matchedExercises"] = [entry["exercise"] for entry in matches]
            row["lastTrained"] = max(entry["lastDate"] for entry in matches)
        if best:
            row["bestE1rmLb"] = best
            if isinstance(target.get("targetLb"), (int, float)) and isinstance(target.get("targetReps"), (int, float)):
                goal_e1rm = e1rm(float(target["targetLb"]), int(target["targetReps"]))
                row["goalE1rmLb"] = round(goal_e1rm)
                row["gapLb"] = max(0, round(goal_e1rm - best))
        elif reps:
            row["bestRepsInASet"] = reps
        if not matches:
            row["status"] = "not trained in 30 days"
        rows.append(row)
    return rows


def week_summary(today: date, runs: list[dict[str, Any]], sessions: list[dict[str, Any]], quest_days: list[dict[str, Any]], weekly_ten_ks: int) -> dict[str, Any]:
    """This Monday-to-Sunday week and the last 7 days, so the plan can meet the weekly 10K count."""
    monday = today - timedelta(days=today.weekday())
    in_week = [run for run in runs if run["date"] >= monday.isoformat()]
    last7 = [run for run in runs if run["daysAgo"] <= 6]
    ten_ks = sum(1 for run in in_week if run.get("counts") == "10K")
    days_left = 7 - today.weekday()
    needed = max(0, weekly_ten_ks - ten_ks)
    return {
        "weekStart": monday.isoformat(),
        "daysLeftIncludingToday": days_left,
        "tenKGoal": weekly_ten_ks,
        "tenKsDone": ten_ks,
        "tenKsStillNeeded": needed,
        "tenKsNeededPerDayLeft": round(needed / days_left, 2) if days_left else 0,
        "runKmThisWeek": round(sum(run["km"] for run in in_week if run.get("counts")), 1),
        "strengthSessionsThisWeek": sum(1 for item in sessions if item["date"] >= monday.isoformat()),
        "last7Days": {
            "tenKs": sum(1 for run in last7 if run.get("counts") == "10K"),
            "runKm": round(sum(run["km"] for run in last7 if run.get("counts")), 1),
            "strengthSessions": sum(1 for item in sessions if item["daysAgo"] <= 6),
            "heavyLowerSessions": sum(1 for item in sessions if item["daysAgo"] <= 6 and item["heavyLower"]),
        },
        "missedQuestDays": [day.get("dayKey") for day in quest_days if day.get("missedRequired")],
    }


# MARK: - Hard limits


def quest_is_heavy_lower(quest: dict[str, Any], lifts: dict[str, dict[str, Any]]) -> bool:
    verification = quest.get("verification") or {}
    params = verification.get("params") or {}
    if verification.get("method") != "hevy_sets" or not isinstance(params, dict):
        return False
    name = base_name(str(params.get("exercise") or quest.get("title") or ""))
    if not HEAVY_LOWER_PATTERN.search(name):
        return False
    best = (lifts.get(name) or {}).get("bestE1rmKg")
    weight = params.get("minWeightKg")
    if isinstance(weight, (int, float)) and best:
        return weight >= HEAVY_SHARE_OF_E1RM * best
    reps = params.get("minReps")
    if isinstance(reps, (int, float)):
        return reps <= HEAVY_REPS_MAX
    return quest.get("difficulty") == "hard"


def is_ten_k(quest: dict[str, Any]) -> bool:
    params = (quest.get("verification") or {}).get("params") or {}
    return isinstance(params, dict) and params.get("minDistanceMeters") == 10_000


def limit_problems(bundle: dict[str, Any], history: dict[str, Any] | None) -> list[str]:
    """Hard limits the model cannot talk its way past. Runs on every generated Training bundle."""
    if bundle.get("mode") != "performance_training":
        return []
    quests = [quest for quest in bundle.get("quests") or [] if isinstance(quest, dict)]
    problems = []
    ten_ks = sum(1 for quest in quests if is_ten_k(quest))
    if ten_ks > MAX_TEN_KS_PER_DAY:
        problems.append(f"more than {MAX_TEN_KS_PER_DAY} 10Ks in one day")
    lifts = (history or {}).get("lifts") or {}
    heavy_today = any(quest_is_heavy_lower(quest, lifts) for quest in quests)
    if not heavy_today:
        return problems
    if ten_ks >= 2:
        problems.append("heavy squats or deadlifts on a two-10K day")
    sessions = (history or {}).get("strengthSessions") or []
    recent = [item["daysAgo"] for item in sessions if item.get("heavyLower")]
    if any(days < HEAVY_LOWER_MIN_DAYS_APART for days in recent):
        problems.append(f"heavy squats or deadlifts less than {HEAVY_LOWER_MIN_DAYS_APART} days after the last heavy lower-body day")
    if len({days for days in recent if 1 <= days <= 6}) + 1 > HEAVY_LOWER_MAX_PER_7_DAYS:
        problems.append(f"more than {HEAVY_LOWER_MAX_PER_7_DAYS} heavy lower-body days in 7")
    return problems


# MARK: - Self-check


def self_check() -> None:
    zone = ZoneInfo("America/Los_Angeles")
    today = date(2026, 10, 22)  # Thursday

    def lift(day: int, title: str, sets: list[tuple[float, int]], rpe: float | None = None) -> dict[str, Any]:
        return {
            "id": f"{title}-{day}",
            "title": "Workout",
            "start": f"2026-10-{day:02d}T17:00:00Z",
            "end": f"2026-10-{day:02d}T18:05:00Z",
            "exercises": [
                {
                    "title": title,
                    "templateId": None,
                    "sets": [{"type": "warmup", "reps": 5, "weightKg": 40.0, "rpe": None, "durationSec": None}]
                    + [{"type": "normal", "reps": reps, "weightKg": kg, "rpe": rpe, "durationSec": None} for kg, reps in sets],
                }
            ],
        }

    def run(day: int, meters: float, moving: float = 3000) -> dict[str, Any]:
        return {"start_date": f"2026-10-{day:02d}T15:00:00Z", "sport_type": "Run", "distance": meters, "moving_time": moving, "average_heartrate": 150.4, "name": "private"}

    workouts = [
        lift(20, "Squat (Barbell)", [(120, 5), (120, 5), (120, 5)], 8),
        lift(15, "Squat (Barbell)", [(80, 10), (80, 10)]),
        lift(21, "Bench Press (Barbell)", [(90, 5), (90, 5)], 8),
    ]
    activities = [run(19, 10_020), run(20, 10_000, 3100), run(21, 5_010, 1500), run(10, 9_000)]
    whoop = {
        "cycles": [{"id": 7, "start": "2026-10-22T06:00:00Z", "score": {"strain": 9.31}}],
        "recoveries": [{"cycle_id": 7, "score": {"recovery_score": 71, "hrv_rmssd_milli": 62.44, "resting_heart_rate": 51}}],
        "sleeps": [{"cycle_id": 7, "nap": False, "score": {"sleep_performance_percentage": 88, "stage_summary": {"total_in_bed_time_milli": 28_800_000, "total_awake_time_milli": 1_800_000}}}],
    }
    goals = {"weeklyTenKs": 5, "strength": [{"category": "Squat", "goal": "315 lb × 1", "aliases": ["squat"], "targetLb": 315, "targetReps": 1}]}
    history = summarize(today, zone, workouts, activities, whoop, goals, [{"dayKey": "2026-10-20", "missedRequired": True}])

    squat = history["lifts"].get("squat")
    if not squat or squat["sessionCount"] != 2 or squat["sessions"][0]["date"] != "2026-10-20" or squat["sessions"][0]["sets"][0] != "120kg (265lb) x5 @8":
        raise SystemExit(f"squat sessions should be newest first without warmups, got {squat}")
    if squat["bestE1rmKg"] != 140.0 or squat["daysSinceLast"] != 2:
        raise SystemExit(f"squat best e1RM should be 140 kg, 2 days ago, got {squat['bestE1rmKg']} {squat['daysSinceLast']}")
    heavy = [item["date"] for item in history["strengthSessions"] if item["heavyLower"]]
    if heavy != ["2026-10-20"]:
        raise SystemExit(f"only the 5-rep squat day should be heavy, got {heavy}")
    week = history["week"]
    if week["weekStart"] != "2026-10-19" or week["tenKsDone"] != 2 or week["tenKsStillNeeded"] != 3 or week["daysLeftIncludingToday"] != 4:
        raise SystemExit(f"week should start Monday with 2 of 5 10Ks done and 4 days left, got {week}")
    if [run["counts"] for run in history["runs"]] != ["5K", "10K", "10K", "5K"] or history["runs"][1]["pacePerKm"] != "5:10":
        raise SystemExit(f"runs should be labeled and paced, got {history['runs']}")
    if "private" in str(history):
        raise SystemExit("Strava activity names must not reach the model")
    if history["recovery"] != [{"date": "2026-10-21", "strain": 9.3, "recovery": 71, "hrv": 62.4, "restingHr": 51, "sleepPerformance": 88, "sleepHours": 7.5}]:
        raise SystemExit(f"recovery row wrong: {history['recovery']}")
    target = history["strengthTargets"][0]
    if target.get("bestE1rmLb") != 309 or target.get("gapLb") != 6 or target.get("lastTrained") != "2026-10-20":
        raise SystemExit(f"squat target should show a 6 lb gap, got {target}")
    if week["missedQuestDays"] != ["2026-10-20"]:
        raise SystemExit("missed quest days should carry through")

    def bundle(*quests: dict[str, Any]) -> dict[str, Any]:
        return {"mode": "performance_training", "quests": list(quests)}

    def hevy(exercise: str, **params: Any) -> dict[str, Any]:
        return {"verification": {"method": "hevy_sets", "params": {"exercise": exercise, "sets": 3, **params}}, "difficulty": "normal"}

    ten_k = {"verification": {"method": "strava_activity", "params": {"types": ["Run"], "minDistanceMeters": 10_000}}}
    # Heavy squats two days after a heavy squat day pass; the next day does not.
    if limit_problems(bundle(hevy("Squat", minReps=5, minWeightKg=125)), history):
        raise SystemExit("heavy squats 2 days after the last heavy day should pass")
    yesterday = dict(history, strengthSessions=[dict(history["strengthSessions"][1], daysAgo=1)])
    if not limit_problems(bundle(hevy("Squat", minReps=5, minWeightKg=125)), yesterday):
        raise SystemExit("heavy squats the day after a heavy squat day should be rejected")
    # Light squats are fine the next day: 90 kg is under 80% of a 140 kg e1RM.
    if limit_problems(bundle(hevy("Squat", minReps=10, minWeightKg=90)), yesterday):
        raise SystemExit("light squats should not count as heavy")
    crowded = dict(history, strengthSessions=[{"daysAgo": 2, "heavyLower": True}, {"daysAgo": 5, "heavyLower": True}])
    if not limit_problems(bundle(hevy("Deadlift", minReps=3)), crowded):
        raise SystemExit("a third heavy lower-body day in 7 should be rejected")
    if not limit_problems(bundle(ten_k, ten_k, hevy("Squat", minReps=5)), history):
        raise SystemExit("heavy squats on a two-10K day should be rejected")
    if not limit_problems(bundle(ten_k, ten_k, ten_k), history):
        raise SystemExit("three 10Ks in a day should be rejected")
    if limit_problems(bundle(ten_k, ten_k, hevy("Bench Press", minReps=5)), history):
        raise SystemExit("two 10Ks and bench press should pass")
    if limit_problems({"mode": "full_recovery", "quests": [ten_k, ten_k, ten_k]}, history):
        raise SystemExit("limits apply only to Training days")
