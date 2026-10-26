"""Local quest generator.

Secrets come from the process environment only. This file has no API key.
Without XAI_API_KEY the handler returns a deterministic template.
With that variable set, it calls xAI Grok and keeps the reply only if it
passes the safety checks; otherwise it returns the template.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from typing import Any

from fastapi import FastAPI, HTTPException, Request

import history
import integrations
import mercury

app = FastAPI(title="the-system quest stub")

MODES = {
    "performance_training",
    "full_recovery",
}
METHODS = {
    "whoop_strain",
    "whoop_recovery",
    "strava_activity",
    "hevy_sets",
    "healthkit_workout",
    "healthkit_nutrition",
    "macrofactor_protein",
    "mercury_spend_under",
    "screen_time_limit",
    "manual_confirm",
    "timer_session",
}
STATS = {"STR", "END", "INT", "AGI", "FOC", "REC", "FIN"}
SECRET_KEYS = {
    "password",
    "apikey",
    "api_key",
    "authorization",
    "secret",
    "token",
    "xai_api_key",
    "openai_api_key",
}
UNSAFE = ("starve", "all-nighter", "all nighter", "ignore injury", "max debt")
XAI_URL = "https://api.x.ai/v1/chat/completions"
DEFAULT_MODEL = "grok-4.6"
# The context holds 30 days of training, so the model needs time to read it. The phone waits longer than this.
GROK_SECONDS = 60.0

SYSTEM_PROMPT = """You are The System, a strength and running coach. Write today's quests as JSON matching QuestBundle.

Goals, in order:
1. Reach the strength targets in trainingHistory.strengthTargets (goal, bestE1rmLb, gapLb). Spend the most work on the biggest gaps that were not trained recently.
2. Run at least goals.weeklyTenKs 10Ks every Monday-to-Sunday week. trainingHistory.week says how many are done and how many are still needed.
   goals.focus lists the targets to put first right now (lateral raises and biceps). The split trains them 3 times a rotation with the most sets: never drop them for time or readiness, and progress them first.
3. Reach the body weight target in goals.bodyWeight. Do not write nutrition quests for it; it only informs how hard to push.

Read the context before you plan:
- trainingHistory.strengthSessions and trainingHistory.lifts hold 30 days of Hevy sets (weight, reps, RPE), newest first.
- trainingHistory.runs holds 30 days of Strava activities with distance, pace, and heart rate.
- trainingHistory.recovery holds 30 days of WHOOP recovery, HRV, resting heart rate, sleep, and strain. whoop holds today's values.
- recentDays holds the quests the app assigned on each past day, and whether each was completed. Do not repeat a plan that was missed; adjust it.
- trainingHistory.sources says which feeds were unavailable. With no data, start conservatively.

Progression (pick loads from the logged sets, never guess):
- Main lifts (squat, deadlift, bench press, overhead press, barbell row, pull-ups, dips): one top set at RPE 8, then 2-3 back-off sets at about 90% of the top set. If the last session's top set reached its reps at RPE 8 or lower, add 2.5 kg for upper-body lifts and 5 kg for squat and deadlift. At RPE 9, repeat the weight. At RPE 10 or a missed rep, drop 5%.
- Accessories (lateral raise, curls, Bulgarian split squat, and other lifts): double progression in an 8-12 rep range. Add reps until every set reaches 12, then add the smallest weight step and go back to 8.
- The split trains bench press, rows, and squats twice a rotation, lateral raises and curls three times, and deadlift and overhead press once.
- Write exact loads. Title: "Squat 3x5 @ 265 lb". Params: exercise (the Hevy name without equipment, e.g. "Squat"), sets, minReps, minWeightKg (the working weight in kg, rounded down to 2.5 kg). Unit "sets".

Gym split (split in the context):
- Follow split.today: write its exercises, in order, with headerLine exactly split.today.name. The split rotates in the order of split.rotation; the app picks today's day.
- Roles: "main" is the day's heavy lift (top set at RPE 8, then back-offs). "light" is a main lift on its light day: keep every set under 80% of the lift's best e1RM and above 6 reps. "accessory" uses double progression in minReps-maxReps. secondsPerSet exercises are timed: params minDurationSec is the total seconds (sets × secondsPerSet), unit "min".
- Use each exercise's Hevy name from trainingHistory.lifts when the player has logged it under one of its aliases; otherwise use split.today exercise.
- You may drop other accessories or a set when readiness or recovery calls for it, but keep the goals.focus exercises. Do not add exercises from other days.
- If splitAdvice says today's heavy lift would break the heavy-leg limits, make today a run-only day: write no lifts and headerLine "Training". The same split day comes back next time.

Fatigue (adjust instead of pushing through):
- Each entry in trainingHistory.lifts has a trend and advice from its newest sessions: improving, steady, stalled, declining, or dropping. Follow the advice for that lift.
- declining: cut that lift's sets by a third and use 5-10% less weight than its last top set. dropping: half the sets at 60-70%. stalled: repeat the weight and add a rep, or drop 5% and build back. Never add weight to a declining or dropping lift; the backend rejects it.
- If trainingHistory.fatigue.deloadRecommended is true, deload the whole day: every lift at half its split sets (rounded up) and 60-70% of its last top set, runs easy. The backend rejects more sets than that.
- Falling reps or loads on the focus lifts mean too much volume, not too little: cut sets before adding any.

Running with lifting:
- Heavy lower-body work interferes with running. Obey trainingHistory.limits: at most heavyLowerMaxPer7Days heavy squat or deadlift days in 7, at least heavyLowerMinDaysApart days apart, and no heavy squats or deadlifts on a two-10K day. The backend rejects any plan that breaks these.
- Put upper-body and light lower-body work on days next to heavy leg days.
- If trainingHistory.week.tenKsStillNeeded is equal to or more than daysLeftIncludingToday, today must have a 10K; if it is more, today needs two 10Ks. Never more than maxTenKsPerDay 10Ks.
- Run easy: a 10K is aerobic work, not a race, unless the week has room.

Readiness:
- modeDecision.trainingBand is WHOOP readiness, one step lower after sleep performance under 60%. Green: full plan. Yellow and red: same exercises, one fewer back-off set and top sets at RPE 7. Every band still gets the run and strength work.
- If constraints.noGymToday is true, the player has no gym today: write no strength quests and give two 10K runs instead.

App rules:
- Obey modeDecision.selectedMode. Do not change it. lockedByRules is authoritative.
- performance_training is strength and 5K or 10K runs only. Lifts use hevy_sets, or healthkit_workout with activityType traditionalStrengthTraining. A run is always a 5K or a 10K: strava_activity with types ["Run"] and minDistanceMeters 5000 or 10000, progress target 5 or 10, unit "km". Prefer the 10K. Two 10Ks on one day are two separate quests. No walks, intervals, sprints, other run distances, protein, nutrition, spending, or stretch quests. The app adds its own Stretching quest.
- Use kind daily or optional only. Never write penalty quests: the app adds them from player.penaltyTier.
- Required quests (kind other than optional) <= constraints.maxRequiredQuests. Optional quests <= constraints.maxOptionalQuests. Total quests <= 9.
- Titles are at most 48 characters. The narrative, at most 280 characters, says why today looks the way it does.
- No run longer than 90 minutes when trainingBand is yellow.
- Do not invent medical diagnoses or extreme deficits. Do not suggest calories under 1500.
- Never use the phrases starve, all-nighter, ignore injury, or max debt.
- Do not include completed, status, evidence, grantedXP, or assignedAt.
- Output ONLY valid JSON with schemaVersion, dayKey, mode, headerLine, quests, and narrative.
"""


def xai_api_key() -> str:
    return os.environ.get("XAI_API_KEY", "").strip()


def xai_model() -> str:
    return os.environ.get("XAI_MODEL", "").strip() or DEFAULT_MODEL


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": "true",
        "author": "grok" if xai_api_key() else "template",
        "model": xai_model(),
        "whoop": "configured" if integrations.configured("whoop") else "missing",
        "strava": "configured" if integrations.configured("strava") else "missing",
        "hevy": "configured" if integrations.hevy_api_key() else "missing",
        "codeforces": "configured" if integrations.codeforces_handle() else "missing",
        "mercury": "configured" if mercury.configured() else "missing",
    }


@app.post("/v1/quests/generate")
def generate(body: dict[str, Any]) -> dict[str, Any]:
    problems = validate_request(body)
    if problems:
        raise HTTPException(status_code=400, detail={"error": "invalid_request", "reasons": problems})
    context = with_history(body)
    bundle = grok_or_none(context) or template_bundle(context)
    bundle = sanitize(bundle, context)
    problems = validate_bundle(bundle, context)
    if problems:
        raise HTTPException(status_code=422, detail={"error": "unsafe", "reasons": problems})
    return bundle


def with_history(body: dict[str, Any]) -> dict[str, Any]:
    """The phone's context plus 30 days of Hevy, Strava, and WHOOP. A failed feed never blocks generation."""
    try:
        training = history.build(body)
    except Exception as error:  # noqa: BLE001 - a broken feed must fall back, not 500
        training = {"sources": {"error": type(error).__name__}}
    context = {**body, "trainingHistory": training}
    advice = split_advice(context)
    if advice:
        context["splitAdvice"] = advice
    return context


def split_today(context: dict[str, Any]) -> dict[str, Any] | None:
    today = (context.get("split") or {}).get("today")
    return today if isinstance(today, dict) and isinstance(today.get("exercises"), list) else None


def split_advice(context: dict[str, Any]) -> str:
    """Says when today's split day is a leg day that the heavy-leg limits would block."""
    today = split_today(context)
    if not today or not today.get("lowerBody"):
        return ""
    main = next((item for item in today["exercises"] if item.get("role") == "main"), None)
    if not main:
        return ""
    probe = {"mode": "performance_training", "quests": [{"verification": {"method": "hevy_sets", "params": {"exercise": main.get("exercise"), "minReps": 1}}}]}
    problems = history.limit_problems(probe, context.get("trainingHistory"))
    if not problems:
        return ""
    return f"Today's {today.get('name')} heavy {main.get('exercise')} would break the limits ({'; '.join(problems)}). Make today a run-only day."


def split_names(exercise: dict[str, Any]) -> set[str]:
    names = {str(exercise.get("exercise") or "")} | {str(alias) for alias in exercise.get("aliases") or []}
    return {history.base_name(name).replace("-", " ") for name in names if name}


def split_problems(bundle: dict[str, Any], context: dict[str, Any]) -> list[str]:
    """On a split day, lifts must come from today's split day, under its name."""
    today = split_today(context)
    if not today or bundle.get("mode") != "performance_training":
        return []
    lifts = [quest for quest in bundle.get("quests") or [] if isinstance(quest, dict) and quest.get("stat") == "STR"]
    if not lifts:
        return []
    problems = []
    if bundle.get("headerLine") != today.get("name"):
        problems.append(f"headerLine must be {today.get('name')} on a split day")
    allowed = set().union(*(split_names(item) for item in today["exercises"]))
    deload = ((context.get("trainingHistory") or {}).get("fatigue") or {}).get("deloadRecommended") is True
    for quest in lifts:
        params = (quest.get("verification") or {}).get("params") or {}
        name = history.base_name(str(params.get("exercise") or "")).replace("-", " ") if isinstance(params, dict) else ""
        planned = next((item for item in today["exercises"] if name in split_names(item)), None)
        sets = params.get("sets") if isinstance(params, dict) else None
        if deload and planned and isinstance(sets, (int, float)) and sets > -(-int(planned.get("sets") or 1) // 2):
            problems.append(f"{quest.get('title')} has too many sets for a deload day")
        verification = quest.get("verification") or {}
        params = verification.get("params") or {}
        name = history.base_name(str(params.get("exercise") or "")).replace("-", " ") if isinstance(params, dict) else ""
        if verification.get("method") != "hevy_sets" or name not in allowed:
            problems.append(f"{quest.get('title')} is not part of {today.get('name')}")
    return problems


def validate_request(body: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    if not isinstance(body, dict):
        return ["body must be an object"]
    if find_secret_keys(body):
        problems.append("request contains a secret field")
    if body.get("schemaVersion") != 1:
        problems.append("schemaVersion must be 1")
    player = body.get("player") or {}
    local_date = player.get("localDate") if isinstance(player, dict) else None
    if not isinstance(local_date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", local_date):
        problems.append("player.localDate is required")
    decision = body.get("modeDecision") or {}
    if not isinstance(decision, dict):
        problems.append("modeDecision is required")
    else:
        mode = decision.get("selectedMode")
        if mode not in MODES:
            problems.append("selectedMode is not a known mode")
        if decision.get("lockedByRules") is not True:
            problems.append("mode must be locked by rules")
    return problems


def find_secret_keys(value: Any) -> bool:
    if isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower().replace("-", "_") in SECRET_KEYS:
                return True
            if find_secret_keys(item):
                return True
    elif isinstance(value, list):
        return any(find_secret_keys(item) for item in value)
    return False


def grok_or_none(context: dict[str, Any]) -> dict[str, Any] | None:
    if not xai_api_key():
        return None
    deadline = time.monotonic() + GROK_SECONDS
    feedback: list[str] = []
    for _ in range(3):
        remaining = deadline - time.monotonic()
        if remaining < 0.5:
            break
        status, raw = call_grok(context, timeout=remaining, feedback=feedback)
        if status == "transport":
            break
        if not isinstance(raw, dict):
            continue
        locked = (context.get("modeDecision") or {}).get("selectedMode")
        if raw.get("mode") != locked:
            continue
        local_date = (context.get("player") or {}).get("localDate")
        if raw.get("dayKey") not in (None, local_date):
            continue
        raw["generatedBy"] = "llm"
        candidate = sanitize(raw, context)
        feedback = validate_bundle(candidate, context)
        if not feedback:
            return candidate
    return None


def call_grok(context: dict[str, Any], timeout: float, feedback: list[str] | None = None) -> tuple[str, dict[str, Any] | None]:
    key = xai_api_key()
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": json.dumps(redact_strings(context))},
    ]
    if feedback:
        # The last plan broke a rule. Say which, so the retry fixes it instead of guessing again.
        messages.append({"role": "user", "content": "Your last plan was rejected: " + "; ".join(sorted(set(feedback))) + ". Write a new plan that fixes this."})
    payload = {
        "model": xai_model(),
        "temperature": 0.4,
        "response_format": {"type": "json_object"},
        "messages": messages,
    }
    request = urllib.request.Request(
        XAI_URL,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            parsed = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return ("transport", None)
    content = ""
    choices = parsed.get("choices") or []
    if choices:
        content = ((choices[0].get("message") or {}).get("content")) or ""
    parsed_bundle = parse_json_object(content)
    if parsed_bundle is None:
        return ("bad", None)
    return ("ok", parsed_bundle)


def parse_json_object(content: str) -> dict[str, Any] | None:
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?", "", text).strip()
        text = re.sub(r"```$", "", text).strip()
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def redact_strings(value: Any) -> Any:
    if isinstance(value, str):
        lower = value.lower()
        if any(marker in lower for marker in ("sk-", "xai-", "bearer ", "api_key", "api-key")):
            return "redacted"
        return value
    if isinstance(value, list):
        return [redact_strings(item) for item in value]
    if isinstance(value, dict):
        return {key: redact_strings(item) for key, item in value.items()}
    return value


def sanitize(bundle: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    player = context.get("player") or {}
    decision = context.get("modeDecision") or {}
    mode = decision.get("selectedMode")
    day = player.get("localDate")
    cleaned = dict(bundle)
    cleaned.pop("completed", None)
    cleaned["schemaVersion"] = 1
    if isinstance(day, str):
        cleaned["dayKey"] = day
    if mode in MODES:
        cleaned["mode"] = mode
    author = cleaned.get("generatedBy")
    cleaned["generatedBy"] = author if author in {"llm", "template", "mock"} else "template"
    quests = []
    for quest in cleaned.get("quests") or []:
        if not isinstance(quest, dict):
            continue
        row = dict(quest)
        for field in ("completed", "status", "evidence", "grantedXP", "grantedStatPoints", "grantedRecoveryToken", "assignedAt"):
            row.pop(field, None)
        xp = row.get("xp")
        if isinstance(xp, float) and xp.is_integer():
            row["xp"] = int(xp)
        if mode in MODES:
            row["mode"] = mode
        progress = row.get("progress")
        if isinstance(progress, dict):
            progress = dict(progress)
            progress["current"] = 0
            row["progress"] = progress
        quests.append(row)
    cleaned["quests"] = quests
    if not cleaned.get("headerLine") and isinstance(mode, str):
        cleaned["headerLine"] = mode.replace("_", " ").title()
    cleaned["warnings"] = cleaned.get("warnings") or ["Failure to complete\nthe daily quest will result\nin a penalty."]
    return cleaned


def validate_bundle(bundle: dict[str, Any], context: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    player = context.get("player") or {}
    decision = context.get("modeDecision") or {}
    constraints = context.get("constraints") or {}
    band = training_band(context)
    if bundle.get("schemaVersion") != 1:
        problems.append("schemaVersion must be 1")
    if bundle.get("dayKey") != player.get("localDate"):
        problems.append("dayKey does not match the local quest day")
    if bundle.get("mode") != decision.get("selectedMode"):
        problems.append("locked mode overridden")
    narrative = bundle.get("narrative") or ""
    if not isinstance(narrative, str) or len(narrative) > 280:
        problems.append("narrative is missing or too long")
    quests = bundle.get("quests") or []
    if not isinstance(quests, list) or not quests:
        problems.append("bundle has no quests")
        quests = []
    required_cap = constraints.get("maxRequiredQuests") or 8
    optional_cap = constraints.get("maxOptionalQuests") or 1
    required = sum(1 for quest in quests if isinstance(quest, dict) and quest.get("kind") != "optional")
    optional = sum(1 for quest in quests if isinstance(quest, dict) and quest.get("kind") == "optional")
    if len(quests) > 9:
        problems.append("too many quests")
    if required > required_cap:
        problems.append("too many required quests")
    if optional > optional_cap:
        problems.append("too many optional quests")
    texts = [narrative, str(bundle.get("headerLine") or "")]
    seen: set[str] = set()
    for quest in quests:
        if not isinstance(quest, dict):
            problems.append("quest must be an object")
            continue
        problems.extend(validate_quest(quest, band, seen))
        if bundle.get("mode") == "performance_training" and not is_training_row(quest):
            problems.append("Training allows only 5K or 10K runs and strength")
        texts.append(str(quest.get("title") or ""))
        params = (quest.get("verification") or {}).get("params") or {}
        if isinstance(params, dict):
            texts.extend(str(value) for value in params.values() if isinstance(value, str))
    problems.extend(history.limit_problems(bundle, context.get("trainingHistory")))
    problems.extend(split_problems(bundle, context))
    haystack = "\n".join(texts).lower()
    if any(phrase in haystack for phrase in UNSAFE):
        problems.append("unsafe phrasing")
    for match in re.finditer(r"(\d{3,4})\s*(kcal|calories)", haystack):
        if int(match.group(1)) < 1500:
            problems.append("calorie suggestion below the floor")
    return problems


def validate_quest(quest: dict[str, Any], band: str, seen: set[str]) -> list[str]:
    problems: list[str] = []
    identifier = str(quest.get("id") or "")
    if not 8 <= len(identifier) <= 64:
        problems.append("quest id length")
    if identifier in seen:
        problems.append("duplicate quest id")
    seen.add(identifier)
    title = str(quest.get("title") or "").strip()
    if not 3 <= len(title) <= 48:
        problems.append("quest title length")
    if quest.get("kind") not in {"daily", "optional"} or quest.get("difficulty") == "penalty":
        problems.append("quest kind")
    if quest.get("stat") not in STATS:
        problems.append("quest stat")
    verification = quest.get("verification") or {}
    method = verification.get("method") if isinstance(verification, dict) else None
    if method not in METHODS:
        problems.append("verification method")
    params = verification.get("params") if isinstance(verification, dict) else {}
    if not isinstance(params, dict):
        params = {}
        problems.append("verification params")
    xp = quest.get("xp")
    if not isinstance(xp, int) or not 5 <= xp <= 200:
        problems.append("xp out of range")
    progress = quest.get("progress") or {}
    target = progress.get("target") if isinstance(progress, dict) else None
    unit = progress.get("unit") if isinstance(progress, dict) else ""
    if not isinstance(target, (int, float)) or target <= 0:
        problems.append("progress target must be positive")
    if "completed" in quest or "status" in quest or "evidence" in quest:
        problems.append("completion field present")
    problems.extend(bound_problems(title, method, params, quest.get("difficulty"), quest.get("stat"), band, target, unit))
    return problems


def bound_problems(title: str, method: str | None, params: dict[str, Any], difficulty: Any, stat: Any, band: str, target: Any, unit: Any) -> list[str]:
    problems: list[str] = []
    protein = method == "macrofactor_protein" or "protein" in title.lower() or "minProteinG" in params
    grams: list[float] = []
    if "minProteinG" in params:
        grams.append(float(params["minProteinG"]))
    if protein and unit == "g" and isinstance(target, (int, float)):
        grams.append(float(target))
    if protein and (not grams or any(value < 80 or value > 250 for value in grams)):
        problems.append("protein outside 80-250g")
    if band == "yellow" and is_run(title, params):
        seconds = duration_sec(params, target, unit)
        if seconds is not None and seconds > 90 * 60:
            problems.append("run longer than 90 minutes on yellow readiness")
    if method == "mercury_spend_under":
        cap = params.get("maxDiscretionaryUsd")
        if cap is None and unit == "usd":
            cap = target
        if not isinstance(cap, (int, float)) or cap < 0 or cap > 2000:
            problems.append("mercury cap out of range")
    for key in ("minKcal", "calorieTarget", "calories", "maxKcal", "calorieFloor"):
        value = params.get(key)
        if isinstance(value, (int, float)) and value < 1500:
            problems.append("calorie suggestion below the floor")
    if unit == "kcal" and isinstance(target, (int, float)) and target < 1500:
        problems.append("calorie suggestion below the floor")
    return problems


FIVE_K_METERS = 5_000
TEN_K_METERS = 10_000
RUN_METERS = {FIVE_K_METERS, TEN_K_METERS}


def is_training_row(quest: dict[str, Any]) -> bool:
    """A Training day is strength and 5K or 10K runs only. Two 10Ks on one day are two rows."""
    verification = quest.get("verification") or {}
    method = verification.get("method")
    params = verification.get("params") or {}
    if not isinstance(params, dict):
        return False
    activity = str(params.get("activityType") or "").lower()
    if method == "hevy_sets" or (method == "healthkit_workout" and "strength" in activity):
        return True
    if params.get("minDistanceMeters") not in RUN_METERS:
        return False
    if method == "strava_activity":
        types = params.get("types") or []
        return isinstance(types, list) and bool(types) and all(str(item).lower() == "run" for item in types)
    return method == "healthkit_workout" and activity == "running"


def is_run(title: str, params: dict[str, Any]) -> bool:
    types = params.get("types") or []
    names = [str(item).lower() for item in types] if isinstance(types, list) else []
    if "run" in names:
        return True
    if names:
        return False
    lowered = title.lower()
    if "walk" in lowered and "run" not in lowered:
        return False
    return "run" in lowered


def duration_sec(params: dict[str, Any], target: Any, unit: Any) -> float | None:
    for key in ("minMovingTimeSec", "minDurationSec", "minSec"):
        if isinstance(params.get(key), (int, float)):
            return float(params[key])
    if unit == "min" and isinstance(target, (int, float)):
        return float(target) * 60
    if unit == "sec" and isinstance(target, (int, float)):
        return float(target)
    return None


def training_band(context: dict[str, Any]) -> str:
    """Band the app chose for the Training day: WHOOP readiness, lowered after a poor night."""
    decision = context.get("modeDecision") or {}
    return decision.get("trainingBand") or (context.get("whoop") or {}).get("readinessBand") or "green"


def template_bundle(context: dict[str, Any]) -> dict[str, Any]:
    player = context["player"]
    decision = context["modeDecision"]
    day = player["localDate"]
    mode = decision["selectedMode"]
    band = training_band(context)
    rows = mode_quests(mode, band, day)
    header = header_for(mode)
    today = split_today(context)
    no_gym = (context.get("constraints") or {}).get("noGymToday") is True
    if mode == "performance_training" and today and not no_gym and not context.get("splitAdvice"):
        rows = [row for row in rows if row["stat"] != "STR"] + split_quests(today, band, day, mode)
        header = str(today.get("name") or header)
    elif mode == "performance_training" and context.get("splitAdvice"):
        rows = [row for row in rows if row["stat"] != "STR"]
    if mode == "performance_training" and no_gym:
        rows = no_gym_quests(rows, day, mode)
    required = [quest for quest in rows if quest["kind"] != "optional"][:8]
    optional = [quest for quest in rows if quest["kind"] == "optional"][:1]
    bundle = {
        "schemaVersion": 1,
        "dayKey": day,
        "mode": mode,
        "headerLine": header,
        "narrative": narrative_for(mode, band),
        "quests": (required + optional)[:9],
        "warnings": ["Failure to complete\nthe daily quest will result\nin a penalty."],
        "generatedBy": "template",
    }
    return bundle


def mode_quests(mode: str, band: str, day: str) -> list[dict[str, Any]]:
    if mode == "full_recovery":
        return [quest(day, "sleep", "Sleep Hygiene", "daily", "REC", "timer_session", {"minSec": 600, "label": "Sleep Hygiene"}, 20, "easy", 10, "min", mode)]
    # Training is strength and 10K runs only; the app adds Stretching.
    run = quest(day, "run_10k", "10K Run", "daily", "END", "strava_activity", {"types": ["Run"], "minDistanceMeters": TEN_K_METERS}, 40, "normal", 10, "km", mode)
    if band in ("yellow", "red"):
        push = quest(day, "push", "Push Session", "daily", "STR", "healthkit_workout", {"activityType": "traditionalStrengthTraining", "minDurationSec": 1800}, 30, "normal", 30, "min", mode)
        return [run, push]
    bench = quest(day, "bench", "Bench Press", "daily", "STR", "hevy_sets", {"exercise": "Bench Press", "sets": 4}, 40, "normal", 4, "sets", mode)
    return [run, bench]


def split_quests(today: dict[str, Any], band: str, day: str, mode: str) -> list[dict[str, Any]]:
    """Today's split exercises without loads, like the app's offline day. Yellow and red take a set off the main lift."""
    rows = []
    for item in today["exercises"]:
        sets = int(item.get("sets") or 3)
        if item.get("role") == "main" and band != "green":
            sets = max(1, sets - 1)
        name = str(item.get("exercise") or "Lift")
        slug = name.lower().replace(" ", "_") + ("_light" if item.get("role") == "light" else "")
        seconds = item.get("secondsPerSet")
        if isinstance(seconds, (int, float)) and seconds > 0:
            params = {"exercise": name, "sets": sets, "minDurationSec": seconds * sets}
            rows.append(quest(day, slug, f"{name} {sets}x{int(seconds)}s", "daily", "STR", "hevy_sets", params, 15, "normal", seconds * sets / 60, "min", mode))
            continue
        low, high = int(item.get("minReps") or 1), int(item.get("maxReps") or 1)
        reps = f"{low}" if low == high else f"{low}-{high}"
        main = item.get("role") == "main"
        params = {"exercise": name, "sets": sets, "minReps": low}
        rows.append(quest(day, slug, f"{name} {sets}x{reps}", "daily", "STR", "hevy_sets", params, 25 if main else 15, "hard" if main else "normal", sets, "sets", mode))
    return rows


def no_gym_quests(rows: list[dict[str, Any]], day: str, mode: str) -> list[dict[str, Any]]:
    """No gym today: the lifts give way to a second 10K."""
    runs = [row for row in rows if row["stat"] != "STR"]
    second = quest(day, "run_10k_2", "Second 10K", "daily", "END", "strava_activity", {"types": ["Run"], "minDistanceMeters": TEN_K_METERS}, 40, "normal", 10, "km", mode)
    return runs + [second]


def quest(day: str, slug: str, title: str, kind: str, stat: str, method: str, params: dict[str, Any], xp: int, difficulty: str, target: float, unit: str, mode: str) -> dict[str, Any]:
    identifier = f"q_{day}_{slug}"[:64]
    row = {
        "id": identifier,
        "title": title[:48],
        "kind": kind,
        "stat": stat,
        "verification": {"method": method, "params": params},
        "deadline": f"{day}T23:59:59Z",
        "xp": xp,
        "difficulty": difficulty,
        "mode": mode,
        "progress": {"current": 0, "target": target, "unit": unit},
    }
    return row


def header_for(mode: str) -> str:
    names = {
        "performance_training": "Training",
        "full_recovery": "Full Recovery Day",
    }
    return names.get(mode, "Daily Quest")


def narrative_for(mode: str, band: str) -> str:
    if band in ("yellow", "red"):
        return "Moderate day. Run the 10K easy and keep the lifting moderate."
    return "The daily quest is waiting."


def sample_request(mode: str = "performance_training", band: str = "green") -> dict[str, Any]:
    body: dict[str, Any] = {
        "schemaVersion": 1,
        "player": {"timezone": "America/Los_Angeles", "localDate": "2026-10-01", "level": 42, "xp": 1, "penaltyTier": 0},
        "modeDecision": {"selectedMode": mode, "trainingBand": band, "reasonCodes": ["fixture"], "lockedByRules": True},
        "whoop": {"available": False, "readinessBand": band},
        "constraints": {"maxRequiredQuests": 8, "maxOptionalQuests": 1},
    }
    return body


SAMPLE_SPLIT_DAY = {
    "id": "squat",
    "name": "Squat Day",
    "lowerBody": True,
    "exercises": [
        {"exercise": "Squat", "aliases": ["squat"], "role": "main", "sets": 4, "minReps": 1, "maxReps": 5},
        {"exercise": "Bulgarian Split Squat", "aliases": ["bulgarian split squat"], "role": "accessory", "sets": 6, "minReps": 8, "maxReps": 12},
        {"exercise": "Dead Hang", "aliases": ["dead hang", "hang"], "role": "accessory", "sets": 3, "minReps": 0, "maxReps": 0, "secondsPerSet": 60},
    ],
}


@app.get("/v1/oauth/whoop/start")
def whoop_start() -> dict[str, str]:
    client_id = integrations.env("WHOOP_CLIENT_ID")
    if not client_id:
        raise HTTPException(status_code=400, detail={"error": "WHOOP_CLIENT_ID is not set"})
    redirect = integrations.env("WHOOP_REDIRECT_URI") or "http://127.0.0.1:8787/v1/oauth/whoop/callback"
    return {"authorizeUrl": integrations.whoop_authorize_url(client_id, redirect, "local")}


@app.get("/v1/oauth/whoop/callback")
def whoop_callback(code: str = "") -> dict[str, Any]:
    return oauth_callback("whoop", code)


@app.post("/v1/oauth/whoop/refresh")
def whoop_refresh() -> dict[str, Any]:
    return oauth_refresh("whoop")


@app.get("/v1/oauth/strava/start")
def strava_start() -> dict[str, str]:
    client_id = integrations.env("STRAVA_CLIENT_ID")
    if not client_id:
        raise HTTPException(status_code=400, detail={"error": "STRAVA_CLIENT_ID is not set"})
    redirect = integrations.env("STRAVA_REDIRECT_URI") or "http://127.0.0.1:8787/v1/oauth/strava/callback"
    return {"authorizeUrl": integrations.strava_authorize_url(client_id, redirect, "local")}


@app.get("/v1/oauth/strava/callback")
def strava_callback(code: str = "") -> dict[str, Any]:
    return oauth_callback("strava", code)


@app.post("/v1/oauth/strava/refresh")
def strava_refresh() -> dict[str, Any]:
    return oauth_refresh("strava")


@app.get("/v1/integrations/whoop/snapshot")
def whoop_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    require_day(day)
    return integrations.public_payload(integrations.whoop_snapshot(day, tz))


@app.get("/v1/integrations/strava/snapshot")
def strava_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    require_day(day)
    return integrations.public_payload(integrations.strava_snapshot(day, tz))


@app.get("/v1/integrations/hevy/snapshot")
def hevy_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    require_day(day)
    return integrations.public_payload(integrations.hevy_snapshot(day, tz))


@app.get("/v1/integrations/codeforces/snapshot")
def codeforces_snapshot() -> dict[str, Any]:
    return integrations.public_payload(integrations.codeforces_snapshot())


@app.post("/v1/webhooks/whoop")
async def whoop_webhook(request: Request) -> dict[str, bool]:
    body = await request.body()
    if not integrations.verify_whoop_signature(
        body,
        request.headers.get("x-whoop-signature-timestamp", ""),
        request.headers.get("x-whoop-signature", ""),
    ):
        raise HTTPException(status_code=401, detail={"error": "invalid signature"})
    return {"ok": True}


@app.get("/v1/webhooks/strava")
def strava_webhook_handshake(request: Request) -> dict[str, str]:
    result = integrations.strava_handshake(dict(request.query_params))
    if result is None:
        raise HTTPException(status_code=401, detail={"error": "invalid subscription"})
    return result


@app.post("/v1/webhooks/strava")
async def strava_webhook(request: Request) -> dict[str, bool]:
    if not integrations.strava_event_allowed():
        raise HTTPException(status_code=401, detail={"error": "STRAVA_WEBHOOK_VERIFY_TOKEN is not set"})
    await request.body()
    return {"ok": True}


@app.post("/v1/integrations/mercury/sync")
def mercury_sync() -> dict[str, Any]:
    if not mercury.configured():
        raise HTTPException(status_code=503, detail={"error": "MERCURY_API_TOKEN is not set"})
    result = mercury.sync()
    if not result:
        raise HTTPException(status_code=503, detail={"error": "Mercury sync failed"})
    return result


@app.get("/v1/integrations/mercury/snapshot")
def mercury_snapshot(day: str) -> dict[str, Any]:
    require_day(day)
    return mercury.snapshot(day)


@app.get("/v1/integrations/mercury/accounts")
def mercury_accounts() -> dict[str, Any]:
    return mercury.accounts_payload()


@app.get("/v1/integrations/mercury/transactions")
def mercury_transactions(limit: int = 100, start_after: str = "") -> dict[str, Any]:
    return mercury.list_cached_transactions(limit=limit, start_after=start_after)


@app.get("/v1/integrations/mercury/month")
def mercury_month(month: str) -> dict[str, Any]:
    if not mercury.valid_month(month):
        raise HTTPException(status_code=400, detail={"error": "month must be YYYY-MM"})
    return mercury.month_snapshot(month)


@app.post("/v1/webhooks/mercury")
async def mercury_webhook(request: Request) -> dict[str, Any]:
    body = await request.body()
    if not mercury.verify_signature(body, request.headers.get("mercury-signature", "")):
        raise HTTPException(status_code=401, detail={"error": "invalid signature"})
    try:
        event = json.loads(body.decode() or "{}")
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail={"error": "invalid json"}) from exc
    if not isinstance(event, dict):
        raise HTTPException(status_code=400, detail={"error": "invalid json"})
    return mercury.ingest_event(event, fetch_transaction=mercury.pull_transaction)


def oauth_callback(provider: str, code: str) -> dict[str, Any]:
    if not code:
        raise HTTPException(status_code=400, detail={"error": "missing code"})
    tokens = integrations.exchange_code(provider, code)
    if not tokens or not tokens.get("access_token"):
        raise HTTPException(status_code=503, detail={"error": f"{provider} token exchange failed"})
    integrations.save_tokens(provider, tokens)
    return {"connected": True, "provider": provider}


def oauth_refresh(provider: str) -> dict[str, Any]:
    tokens = integrations.refresh_tokens(provider)
    if not tokens or not tokens.get("access_token"):
        raise HTTPException(status_code=503, detail={"error": f"{provider} refresh failed"})
    return {"connected": True, "provider": provider}


def require_day(day: str) -> None:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        raise HTTPException(status_code=400, detail={"error": "day must be YYYY-MM-DD"})


def self_check() -> None:
    integrations.self_check()
    mercury.self_check()
    history.self_check()
    source = open(__file__, encoding="utf-8").read()
    if "api." + "openai.com" in source:
        raise SystemExit("openai endpoint is not the quest author")
    if re.search(r"XAI_API_KEY\s*=\s*['\"][^'\"]+['\"]", source):
        raise SystemExit("a key was written into the source")
    for name in (".env.example", "README.md"):
        path = os.path.join(os.path.dirname(__file__), name)
        text = open(path, encoding="utf-8").read()
        if re.search(r"(sk-|xai-)[A-Za-z0-9]{8,}", text):
            raise SystemExit(f"{name} contains a key-shaped token")
    bands = ("green", "yellow", "red")
    for mode in sorted(MODES):
        for band in bands:
            body = sample_request(mode, band)
            bundle = sanitize(template_bundle(body), body)
            problems = validate_bundle(bundle, body)
            if problems:
                raise SystemExit(f"template {mode}/{band} failed: {problems}")
            if bundle["mode"] != mode or bundle["generatedBy"] != "template":
                raise SystemExit("template did not keep the locked mode")
            blob = json.dumps(bundle)
            if "completed" in blob or "status" in blob:
                raise SystemExit("template included a completion field")
    def expect_rejected(bundle: dict[str, Any], body: dict[str, Any], label: str) -> None:
        if not validate_bundle(bundle, body):
            raise SystemExit(f"expected rejection: {label}")

    base = template_bundle(sample_request())
    flipped = json.loads(json.dumps(base))
    flipped["mode"] = "full_recovery"
    expect_rejected(flipped, sample_request(), "mode override")
    low = json.loads(json.dumps(base))
    low["quests"][0] = quest("2026-10-01", "protein", "Protein", "daily", "END", "macrofactor_protein", {"minProteinG": 40}, 20, "easy", 40, "g", "performance_training")
    expect_rejected(low, sample_request(), "low protein")
    yellow = sample_request("performance_training", "yellow")
    long_run = template_bundle(yellow)
    long_run["quests"][0] = quest("2026-10-01", "long_run", "Long Run", "daily", "END", "strava_activity", {"types": ["Run"], "minMovingTimeSec": 6000}, 20, "normal", 100, "min", "performance_training")
    expect_rejected(long_run, yellow, "yellow long run")
    red = sample_request("performance_training", "red")
    lift = template_bundle(red)
    lift["quests"][1] = quest("2026-10-01", "max_lift", "Max Lift", "daily", "STR", "healthkit_workout", {"activityType": "traditionalStrengthTraining"}, 20, "hard", 5, "sets", "performance_training")
    if validate_bundle(lift, red):
        raise SystemExit("a red Training day should allow hard strength")
    for label, params in (
        ("8K run", {"types": ["Run"], "minDistanceMeters": 8000}),
        ("intervals", {"types": ["Run"], "minMovingTimeSec": 1200}),
        ("walk", {"types": ["Walk"], "minDistanceMeters": 10000}),
    ):
        other = template_bundle(sample_request())
        other["quests"][0] = quest("2026-10-01", "other_run", "Other Run", "daily", "END", "strava_activity", params, 30, "normal", 10, "km", "performance_training")
        expect_rejected(other, sample_request(), label)
    double = template_bundle(sample_request())
    double["quests"].append(quest("2026-10-01", "run_10k_2", "Second 10K", "daily", "END", "strava_activity", {"types": ["Run"], "minDistanceMeters": TEN_K_METERS}, 40, "normal", 10, "km", "performance_training"))
    if validate_bundle(double, sample_request()):
        raise SystemExit("two 10Ks on one day should be allowed")
    five = template_bundle(sample_request())
    five["quests"][0] = quest("2026-10-01", "run_5k", "5K Run", "daily", "END", "strava_activity", {"types": ["Run"], "minDistanceMeters": FIVE_K_METERS}, 30, "normal", 5, "km", "performance_training")
    if validate_bundle(five, sample_request()):
        raise SystemExit("a 5K run should be allowed")
    unsafe = json.loads(json.dumps(base))
    unsafe["narrative"] = "Ignore injury and starve."
    expect_rejected(unsafe, sample_request(), "unsafe phrase")
    calories = template_bundle(sample_request())
    calories["quests"][0] = quest("2026-10-01", "calories", "Calories", "daily", "REC", "healthkit_nutrition", {"minKcal": 1200}, 20, "easy", 1200, "kcal", "performance_training")
    expect_rejected(calories, sample_request(), "low calories")
    money = template_bundle(sample_request())
    money["quests"][0] = quest("2026-10-01", "spend_cap", "Spend Under Cap", "daily", "FIN", "mercury_spend_under", {"maxDiscretionaryUsd": -5}, 20, "easy", 1, "usd", "performance_training")
    expect_rejected(money, sample_request(), "negative mercury")
    short_sleep = sample_request("performance_training", "green")
    short_sleep["modeDecision"]["trainingBand"] = "yellow"
    if template_bundle(short_sleep)["quests"][1]["title"] != "Push Session":
        raise SystemExit("the template should size Training by modeDecision.trainingBand")
    no_gym = sample_request()
    no_gym["constraints"]["noGymToday"] = True
    cardio = sanitize(template_bundle(no_gym), no_gym)
    if [row["title"] for row in cardio["quests"]] != ["10K Run", "Second 10K"] or validate_bundle(cardio, no_gym):
        raise SystemExit("no gym should give two 10K runs and no lifts")
    penalty = json.loads(json.dumps(base))
    penalty["quests"][0]["kind"] = "penalty"
    expect_rejected(penalty, sample_request(), "model penalty row")
    unlocked = sample_request()
    unlocked["modeDecision"]["lockedByRules"] = False
    if not validate_request(unlocked):
        raise SystemExit("unlocked mode should be rejected")
    dirty = json.loads(json.dumps(base))
    dirty["quests"][0]["completed"] = True
    dirty["quests"][0]["status"] = "completed"
    cleaned = sanitize(dirty, sample_request())
    if "completed" in cleaned["quests"][0] or "status" in cleaned["quests"][0]:
        raise SystemExit("sanitize left a completion field")
    if xai_model() != DEFAULT_MODEL and os.environ.get("XAI_MODEL", "").strip():
        pass
    if os.environ.get("XAI_MODEL", "").strip() == "" and xai_model() != DEFAULT_MODEL:
        raise SystemExit("default model should be grok-4.6")
    split_checks()
    print("ok")


def split_checks() -> None:
    body = sample_request()
    body["split"] = {"name": "4-day upper/lower", "rotation": ["Bench Day", "Squat Day"], "today": SAMPLE_SPLIT_DAY, "lastDone": {}}
    body["trainingHistory"] = {"lifts": {}, "strengthSessions": []}
    day = template_bundle(body)
    titles = [row["title"] for row in day["quests"]]
    if day["headerLine"] != "Squat Day" or titles != ["10K Run", "Squat 4x1-5", "Bulgarian Split Squat 6x8-12", "Dead Hang 3x60s"]:
        raise SystemExit(f"the template should follow today's split day, got {day['headerLine']} {titles}")
    if validate_bundle(sanitize(day, body), body):
        raise SystemExit(f"the split template should pass, got {validate_bundle(sanitize(day, body), body)}")
    if day["quests"][3]["verification"]["params"]["minDurationSec"] != 180:
        raise SystemExit("a timed split exercise should check total seconds")
    renamed = json.loads(json.dumps(day))
    renamed["headerLine"] = "Leg Day"
    if not any("headerLine" in problem for problem in validate_bundle(renamed, body)):
        raise SystemExit("a split day must keep its name")
    other = json.loads(json.dumps(day))
    other["quests"][1]["verification"]["params"]["exercise"] = "Bench Press"
    if not any("not part of Squat Day" in problem for problem in validate_bundle(other, body)):
        raise SystemExit("a lift from another split day should be rejected")
    logged = json.loads(json.dumps(day))
    logged["quests"][3]["verification"]["params"]["exercise"] = "Hang"
    if validate_bundle(logged, body):
        raise SystemExit("an alias of a split exercise should pass")
    tired = dict(body, trainingHistory={"lifts": {}, "strengthSessions": [], "fatigue": {"deloadRecommended": True}})
    if not any("deload" in problem for problem in validate_bundle(day, tired)):
        raise SystemExit("a full-volume day should be rejected when a deload is due")
    halved = json.loads(json.dumps(day))
    for row in halved["quests"][1:]:
        row["verification"]["params"]["sets"] = -(-row["verification"]["params"]["sets"] // 2)
    if any("deload" in problem for problem in validate_bundle(halved, tired)):
        raise SystemExit("half the sets should pass on a deload day")
    run_only = json.loads(json.dumps(day))
    run_only["quests"] = run_only["quests"][:1]
    run_only["headerLine"] = "Training"
    if validate_bundle(run_only, body):
        raise SystemExit("a run-only day may leave the split for the day")
    # A heavy leg day yesterday: the split asks for a run-only day, and the template gives one.
    blocked = dict(body, trainingHistory={"lifts": {}, "strengthSessions": [{"daysAgo": 1, "heavyLower": True}]})
    blocked = {**blocked, "splitAdvice": split_advice(blocked)}
    if "run-only" not in blocked["splitAdvice"] or any(row["stat"] == "STR" for row in template_bundle(blocked)["quests"]):
        raise SystemExit(f"a blocked leg day should become run-only, got {blocked['splitAdvice']}")


if __name__ == "__main__":
    import sys

    if "--check" in sys.argv:
        self_check()
    else:
        import uvicorn

        uvicorn.run(app, host="127.0.0.1", port=8787)
