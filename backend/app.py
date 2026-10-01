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

from fastapi import FastAPI, HTTPException

app = FastAPI(title="the-system quest stub")

MODES = {
    "performance_training",
    "interview_prep",
    "study_block",
    "recovery",
    "full_recovery",
    "nutrition_focus",
    "finance_discipline",
    "focus_deepwork",
    "hybrid",
    "penalty",
}
METHODS = {
    "whoop_strain",
    "whoop_recovery",
    "strava_activity",
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

SYSTEM_PROMPT = """You are The System. Generate today's quests as JSON matching QuestBundle.
Rules:
- Obey modeDecision.selectedMode. Do not change it. lockedByRules is authoritative.
- Do not invent medical diagnoses or extreme deficits.
- Use only the verification methods already defined for this app.
- Required quests (kind other than optional) <= constraints.maxRequiredQuests. Optional quests <= constraints.maxOptionalQuests. Total quests <= 8.
- Titles are short and actionable. Narrative is at most 280 characters.
- If activeTarget is present, include every dailyRequirements entry as a target_injection quest. Do not drop one.
- Scale physical load from whoop.readinessBand: green full, yellow moderate, red recovery only.
- Protein targets stay between 80 and 250 grams.
- No run longer than 90 minutes when readiness is yellow.
- No hard STR session when readiness is red.
- Do not suggest calories under 1500.
- Mercury discretionary cap must be between 0 and 2000 USD.
- Never use the phrases starve, all-nighter, ignore injury, or max debt.
- Do not include completed, status, evidence, grantedXP, or assignedAt.
- Output ONLY valid JSON with schemaVersion, dayKey, mode, quests, and narrative.
"""


def xai_api_key() -> str:
    return os.environ.get("XAI_API_KEY", "").strip()


def xai_model() -> str:
    return os.environ.get("XAI_MODEL", "").strip() or DEFAULT_MODEL


@app.get("/health")
def health() -> dict[str, str]:
    return {"ok": "true", "author": "grok" if xai_api_key() else "template", "model": xai_model()}


@app.post("/v1/quests/generate")
def generate(body: dict[str, Any]) -> dict[str, Any]:
    problems = validate_request(body)
    if problems:
        raise HTTPException(status_code=400, detail={"error": "invalid_request", "reasons": problems})
    bundle = grok_or_none(body) or template_bundle(body)
    bundle = sanitize(bundle, body)
    problems = validate_bundle(bundle, body)
    if problems:
        raise HTTPException(status_code=422, detail={"error": "unsafe", "reasons": problems})
    return bundle


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
    deadline = time.monotonic() + 6.5
    for _ in range(3):
        remaining = deadline - time.monotonic()
        if remaining < 0.5:
            break
        status, raw = call_grok(context, timeout=remaining)
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
        if not validate_bundle(candidate, context):
            return candidate
    return None


def call_grok(context: dict[str, Any], timeout: float) -> tuple[str, dict[str, Any] | None]:
    key = xai_api_key()
    payload = {
        "model": xai_model(),
        "temperature": 0.4,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": json.dumps(redact_strings(context))},
        ],
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
    band = ((context.get("whoop") or {}).get("readinessBand")) or "green"
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
    required_cap = constraints.get("maxRequiredQuests") or 5
    optional_cap = constraints.get("maxOptionalQuests") or 1
    required = sum(1 for quest in quests if isinstance(quest, dict) and quest.get("kind") != "optional")
    optional = sum(1 for quest in quests if isinstance(quest, dict) and quest.get("kind") == "optional")
    if len(quests) > 8:
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
        texts.append(str(quest.get("title") or ""))
        params = (quest.get("verification") or {}).get("params") or {}
        if isinstance(params, dict):
            texts.extend(str(value) for value in params.values() if isinstance(value, str))
    haystack = "\n".join(texts).lower()
    if any(phrase in haystack for phrase in UNSAFE):
        problems.append("unsafe phrasing")
    for match in re.finditer(r"(\d{3,4})\s*(kcal|calories)", haystack):
        if int(match.group(1)) < 1500:
            problems.append("calorie suggestion below the floor")
    target = context.get("activeTarget") or {}
    for requirement in target.get("dailyRequirements") or []:
        title = str((requirement or {}).get("title") or "").strip()
        present = any(
            isinstance(quest, dict) and quest.get("kind") == "target_injection" and quest.get("title") == title
            for quest in quests
        )
        if title and not present:
            problems.append(f"missing target injection {title}")
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
    if quest.get("kind") not in {"daily", "optional", "target_injection", "penalty"}:
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
    if band == "red" and stat == "STR" and difficulty == "hard":
        problems.append("hard strength session on red readiness")
    activity = str(params.get("activityType") or "").lower()
    if band == "red" and "strength" in activity and difficulty == "hard":
        problems.append("hard strength session on red readiness")
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


def template_bundle(context: dict[str, Any]) -> dict[str, Any]:
    player = context["player"]
    decision = context["modeDecision"]
    day = player["localDate"]
    mode = decision["selectedMode"]
    band = ((context.get("whoop") or {}).get("readinessBand")) or "green"
    quests = injections(context.get("activeTarget"), day, mode)
    room = 5 - len(quests)
    extras = [quest for quest in mode_quests(mode, band, day) if quest["kind"] != "target_injection"]
    required = [quest for quest in extras if quest["kind"] != "optional"][: max(room, 0)]
    optional = [quest for quest in extras if quest["kind"] == "optional"][:1]
    bundle = {
        "schemaVersion": 1,
        "dayKey": day,
        "mode": mode,
        "headerLine": header_for(mode),
        "narrative": narrative_for(mode, band),
        "quests": (quests + required + optional)[:8],
        "warnings": ["Failure to complete\nthe daily quest will result\nin a penalty."],
        "generatedBy": "template",
    }
    return bundle


def injections(target: Any, day: str, mode: str) -> list[dict[str, Any]]:
    if not isinstance(target, dict):
        return []
    rows = []
    for requirement in target.get("dailyRequirements") or []:
        if not isinstance(requirement, dict):
            continue
        title = str(requirement.get("title") or "Target Work").strip()[:48]
        quota = requirement.get("quota") or 1
        if not isinstance(quota, (int, float)) or quota <= 0:
            quota = 1
        stat = requirement.get("stat") if requirement.get("stat") in STATS else "INT"
        method = requirement.get("verification") if requirement.get("verification") in METHODS else "manual_confirm"
        slug = re.sub(r"[^a-z0-9]+", "", str(requirement.get("templateId") or "req").lower())[:20] or "req"
        rows.append(
            quest(
                day,
                f"tgt_{slug}",
                title,
                "target_injection",
                stat,
                method,
                {"prompt": f"Confirm {title}"},
                40,
                "normal",
                quota,
                "problems",
                mode,
                target.get("id"),
            )
        )
    return rows


def mode_quests(mode: str, band: str, day: str) -> list[dict[str, Any]]:
    protein = quest(day, "protein", "Protein", "daily", "END", "macrofactor_protein", {"minProteinG": 150}, 25, "easy", 150, "g", mode)
    mobility = quest(day, "mobility", "Mobility", "daily", "AGI", "timer_session", {"minSec": 600, "label": "Mobility"}, 20, "easy", 10, "min", mode)
    if mode == "recovery" or (mode == "performance_training" and band == "red"):
        walk = quest(day, "easy_walk", "Easy Walk", "daily", "REC", "timer_session", {"minSec": 900, "label": "Easy Walk"}, 15, "easy", 15, "min", mode)
        sleep = quest(day, "sleep", "Sleep Hygiene", "daily", "REC", "whoop_recovery", {"minRecoveryScore": 40}, 20, "easy", 1, "session", mode)
        return [sleep, mobility, protein, walk]
    if mode == "full_recovery":
        return [quest(day, "sleep", "Sleep Hygiene", "daily", "REC", "timer_session", {"minSec": 600, "label": "Sleep Hygiene"}, 20, "easy", 10, "min", mode)]
    if mode == "penalty":
        run = quest(day, "penalty_run", "Penalty Run", "penalty", "END", "strava_activity", {"types": ["Run"], "minMovingTimeSec": 1800}, 30, "penalty", 30, "min", mode)
        return [run, mobility, protein]
    if mode == "hybrid" or mode == "interview_prep":
        cards = quest(day, "leetcode", "LeetCode Mediums", "target_injection", "INT", "manual_confirm", {"prompt": "Confirm 3 LeetCode mediums solved"}, 40, "normal", 3, "problems", mode)
        easy = quest(day, "easy_run", "Easy Run", "daily", "END", "strava_activity", {"types": ["Run"], "minMovingTimeSec": 1200}, 25, "easy", 20, "min", mode)
        rows = [cards, easy, protein] if mode == "interview_prep" else [easy, protein]
        return rows
    if mode == "study_block":
        study = quest(day, "study", "Study Block", "daily", "INT", "timer_session", {"minSec": 1500, "label": "Study"}, 30, "normal", 25, "min", mode)
        return [study, protein]
    if mode == "nutrition_focus":
        calories = quest(day, "calories", "Calories", "daily", "REC", "healthkit_nutrition", {"nutrient": "dietaryEnergy", "minKcal": 1800}, 20, "easy", 1800, "kcal", mode)
        return [protein, calories]
    if mode == "finance_discipline":
        cap = quest(day, "spend_cap", "Spend Under Cap", "daily", "FIN", "mercury_spend_under", {"maxDiscretionaryUsd": 40}, 30, "normal", 40, "usd", mode)
        review = quest(day, "review_spend", "Review Spend", "daily", "FIN", "manual_confirm", {"prompt": "Confirm today's discretionary spend was reviewed"}, 15, "easy", 1, "session", mode)
        return [cap, review]
    if mode == "focus_deepwork":
        block = quest(day, "deep_work", "Deep Work", "daily", "FOC", "timer_session", {"minSec": 3000, "label": "Deep Work"}, 30, "normal", 50, "min", mode)
        return [block, protein]
    if band == "yellow":
        zone = quest(day, "zone2", "Zone 2 Walk/Run", "daily", "END", "strava_activity", {"types": ["Run", "Walk"], "minMovingTimeSec": 1200}, 30, "normal", 20, "min", mode)
        push = quest(day, "push", "Push Session", "daily", "STR", "healthkit_workout", {"activityType": "traditionalStrengthTraining", "minDurationSec": 1800}, 30, "normal", 30, "min", mode)
        return [zone, push, mobility, protein]
    run = quest(day, "run_intervals", "Run Intervals", "daily", "END", "strava_activity", {"types": ["Run"], "minMovingTimeSec": 1200}, 40, "normal", 6, "reps", mode)
    bench = quest(day, "bench", "Bench Press", "daily", "STR", "healthkit_workout", {"activityType": "traditionalStrengthTraining", "minDurationSec": 1800}, 40, "normal", 4, "sets", mode)
    return [run, bench, mobility, protein]


def quest(day: str, slug: str, title: str, kind: str, stat: str, method: str, params: dict[str, Any], xp: int, difficulty: str, target: float, unit: str, mode: str, target_id: str | None = None) -> dict[str, Any]:
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
    if target_id:
        row["targetId"] = target_id
    return row


def header_for(mode: str) -> str:
    names = {
        "performance_training": "Performance Training",
        "interview_prep": "Interview Prep",
        "study_block": "Study Block",
        "recovery": "Recovery",
        "full_recovery": "Full Recovery Day",
        "nutrition_focus": "Nutrition Focus",
        "finance_discipline": "Finance Discipline",
        "focus_deepwork": "Deep Work",
        "hybrid": "Hybrid Training",
        "penalty": "Penalty Quest",
    }
    return names.get(mode, "Daily Quest")


def narrative_for(mode: str, band: str) -> str:
    if mode == "recovery" or band == "red":
        return "Red day. Sleep and a short mobility block."
    if mode == "hybrid":
        return "Target window open. Keep the work inside the locked mode."
    if mode == "penalty":
        return "Clear the penalty rows."
    return "The daily quest is waiting."


def sample_request(mode: str = "performance_training", band: str = "green", target: dict[str, Any] | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "schemaVersion": 1,
        "player": {"timezone": "America/Los_Angeles", "localDate": "2026-10-01", "level": 42, "xp": 1, "penaltyTier": 0},
        "modeDecision": {"selectedMode": mode, "reasonCodes": ["fixture"], "lockedByRules": True},
        "whoop": {"available": False, "readinessBand": band},
        "constraints": {"maxRequiredQuests": 5, "maxOptionalQuests": 1},
    }
    if target:
        body["activeTarget"] = target
    return body


def self_check() -> None:
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
    hybrid = sample_request(
        "hybrid",
        "green",
        {
            "id": "tgt_interview",
            "title": "Interview Prep",
            "dailyRequirements": [
                {"templateId": "leetcode", "title": "LeetCode Mediums", "quota": 3, "stat": "INT", "verification": "manual_confirm"}
            ],
        },
    )
    hybrid_bundle = template_bundle(hybrid)
    if validate_bundle(hybrid_bundle, hybrid):
        raise SystemExit(f"hybrid template failed: {validate_bundle(hybrid_bundle, hybrid)}")
    titles = [quest["title"] for quest in hybrid_bundle["quests"] if quest["kind"] == "target_injection"]
    if "LeetCode Mediums" not in titles:
        raise SystemExit("hybrid template dropped the target")

    def expect_rejected(bundle: dict[str, Any], body: dict[str, Any], label: str) -> None:
        if not validate_bundle(bundle, body):
            raise SystemExit(f"expected rejection: {label}")

    base = template_bundle(sample_request())
    flipped = json.loads(json.dumps(base))
    flipped["mode"] = "recovery"
    expect_rejected(flipped, sample_request(), "mode override")
    low = json.loads(json.dumps(base))
    low["quests"][0] = quest("2026-10-01", "protein", "Protein", "daily", "END", "macrofactor_protein", {"minProteinG": 40}, 20, "easy", 40, "g", "performance_training")
    expect_rejected(low, sample_request(), "low protein")
    yellow = sample_request("performance_training", "yellow")
    long_run = template_bundle(yellow)
    long_run["quests"][0] = quest("2026-10-01", "long_run", "Long Run", "daily", "END", "strava_activity", {"types": ["Run"], "minMovingTimeSec": 6000}, 20, "normal", 100, "min", "performance_training")
    expect_rejected(long_run, yellow, "yellow long run")
    red = sample_request("recovery", "red")
    lift = template_bundle(red)
    lift["quests"][0] = quest("2026-10-01", "max_lift", "Max Lift", "daily", "STR", "healthkit_workout", {"activityType": "traditionalStrengthTraining"}, 20, "hard", 5, "sets", "recovery")
    expect_rejected(lift, red, "hard strength")
    unsafe = json.loads(json.dumps(base))
    unsafe["narrative"] = "Ignore injury and starve."
    expect_rejected(unsafe, sample_request(), "unsafe phrase")
    calories = template_bundle(sample_request("nutrition_focus", "green"))
    calories["quests"][0] = quest("2026-10-01", "calories", "Calories", "daily", "REC", "healthkit_nutrition", {"minKcal": 1200}, 20, "easy", 1200, "kcal", "nutrition_focus")
    expect_rejected(calories, sample_request("nutrition_focus"), "low calories")
    money = template_bundle(sample_request("finance_discipline"))
    money["quests"][0] = quest("2026-10-01", "spend_cap", "Spend Under Cap", "daily", "FIN", "mercury_spend_under", {"maxDiscretionaryUsd": -5}, 20, "easy", 1, "usd", "finance_discipline")
    expect_rejected(money, sample_request("finance_discipline"), "negative mercury")
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
    print("ok")


if __name__ == "__main__":
    import sys

    if "--check" in sys.argv:
        self_check()
    else:
        import uvicorn

        uvicorn.run(app, host="127.0.0.1", port=8787)
