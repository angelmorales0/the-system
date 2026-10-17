"""WHOOP and Strava OAuth stubs, and the Hevy API-key reader.

Client secrets and refresh tokens stay in the process environment or in
backend/.secrets (gitignored). Responses never include them.
"""

from __future__ import annotations

import base64
import hashlib
import re
import hmac
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

LA = ZoneInfo("America/Los_Angeles")
WHOOP_AUTH = "https://api.prod.whoop.com/oauth/oauth2/auth"
WHOOP_TOKEN = "https://api.prod.whoop.com/oauth/oauth2/token"
WHOOP_API = "https://api.prod.whoop.com/developer"
STRAVA_AUTH = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN = "https://www.strava.com/oauth/token"
STRAVA_API = "https://www.strava.com/api/v3"
WHOOP_SCOPES = "offline read:recovery read:sleep read:cycles read:workout read:body_measurement"
STRAVA_SCOPES = "activity:read_all"
HEVY_API = "https://api.hevyapp.com"
# Hevy pages are at most 10 workouts. Newest first, so a few pages reach any recent day.
HEVY_PAGE_SIZE = 10
HEVY_MAX_PAGES = 5


def secrets_dir() -> str:
    return os.environ.get("SECRETS_DIR", os.path.join(os.path.dirname(__file__), ".secrets"))


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def configured(provider: str) -> bool:
    prefix = provider.upper()
    if env(f"{prefix}_ACCESS_TOKEN") or env(f"{prefix}_REFRESH_TOKEN"):
        return True
    return os.path.exists(os.path.join(secrets_dir(), f"{provider}.json"))


def load_tokens(provider: str) -> dict[str, Any]:
    prefix = provider.upper()
    tokens: dict[str, Any] = {}
    path = os.path.join(secrets_dir(), f"{provider}.json")
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                stored = json.load(handle)
            if isinstance(stored, dict):
                tokens.update(stored)
        except (OSError, json.JSONDecodeError):
            tokens = {}
    if env(f"{prefix}_ACCESS_TOKEN"):
        tokens["access_token"] = env(f"{prefix}_ACCESS_TOKEN")
    if env(f"{prefix}_REFRESH_TOKEN"):
        tokens["refresh_token"] = env(f"{prefix}_REFRESH_TOKEN")
    if env(f"{prefix}_EXPIRES_AT"):
        try:
            tokens["expires_at"] = int(env(f"{prefix}_EXPIRES_AT"))
        except ValueError:
            pass
    return tokens


def save_tokens(provider: str, tokens: dict[str, Any]) -> None:
    os.makedirs(secrets_dir(), mode=0o700, exist_ok=True)
    path = os.path.join(secrets_dir(), f"{provider}.json")
    payload = {
        "access_token": tokens.get("access_token", ""),
        "refresh_token": tokens.get("refresh_token", ""),
        "expires_at": tokens.get("expires_at", 0),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.chmod(path, 0o600)


def whoop_authorize_url(client_id: str, redirect_uri: str, state: str) -> str:
    query = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": WHOOP_SCOPES,
            "state": state,
        }
    )
    return f"{WHOOP_AUTH}?{query}"


def strava_authorize_url(client_id: str, redirect_uri: str, state: str) -> str:
    query = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "approval_prompt": "auto",
            "scope": STRAVA_SCOPES,
            "state": state,
        }
    )
    return f"{STRAVA_AUTH}?{query}"


def exchange_code(provider: str, code: str) -> dict[str, Any] | None:
    if provider == "whoop":
        body = {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": env("WHOOP_CLIENT_ID"),
            "client_secret": env("WHOOP_CLIENT_SECRET"),
            "redirect_uri": env("WHOOP_REDIRECT_URI") or "http://127.0.0.1:8787/v1/oauth/whoop/callback",
        }
        url = WHOOP_TOKEN
    else:
        body = {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": env("STRAVA_CLIENT_ID"),
            "client_secret": env("STRAVA_CLIENT_SECRET"),
        }
        url = STRAVA_TOKEN
    if not body["client_id"] or not body["client_secret"]:
        return None
    return post_form(url, body)


def refresh_tokens(provider: str) -> dict[str, Any] | None:
    """WHOOP rotates the refresh token on each use. The new token replaces the stored one."""
    current = load_tokens(provider)
    refresh = str(current.get("refresh_token") or "")
    if not refresh:
        return None
    if provider == "whoop":
        body = {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": env("WHOOP_CLIENT_ID"),
            "client_secret": env("WHOOP_CLIENT_SECRET"),
            "scope": WHOOP_SCOPES,
        }
        url = WHOOP_TOKEN
    else:
        body = {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": env("STRAVA_CLIENT_ID"),
            "client_secret": env("STRAVA_CLIENT_SECRET"),
        }
        url = STRAVA_TOKEN
    if not body["client_id"] or not body["client_secret"]:
        return None
    refreshed = post_form(url, body)
    if refreshed and refreshed.get("access_token"):
        save_tokens(provider, refreshed)
    return refreshed


def post_form(url: str, body: dict[str, str]) -> dict[str, Any] | None:
    data = urllib.parse.urlencode(body).encode()
    request = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            parsed = json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None
    if not isinstance(parsed, dict):
        return None
    expires_in = parsed.get("expires_in")
    if isinstance(expires_in, (int, float)):
        parsed["expires_at"] = int(datetime.now().timestamp()) + int(expires_in)
    return parsed


def access_token(provider: str) -> str | None:
    tokens = load_tokens(provider)
    token = str(tokens.get("access_token") or "")
    expires = tokens.get("expires_at") or 0
    if token and isinstance(expires, (int, float)) and expires and expires < datetime.now().timestamp() + 60:
        refreshed = refresh_tokens(provider)
        if not refreshed:
            return None
        token = str(refreshed.get("access_token") or "")
    if not token and tokens.get("refresh_token"):
        refreshed = refresh_tokens(provider)
        token = str((refreshed or {}).get("access_token") or "")
    return token or None


def whoop_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    base = empty_whoop(day)
    if not configured("whoop"):
        base["reason"] = "TODO: WHOOP tokens are not configured on the backend."
        return base
    token = access_token("whoop")
    if not token:
        base["configured"] = True
        base["reason"] = "TODO: WHOOP token refresh failed."
        return base
    start, end = day_bounds(day, tz)
    recovery = whoop_collection(token, "/v2/recovery", start, end)
    cycle = whoop_collection(token, "/v2/cycle", start, end)
    sleep = whoop_collection(token, "/v2/activity/sleep", start, end)
    workouts = whoop_collection(token, "/v2/activity/workout", start, end)
    if recovery is None and cycle is None and workouts is None:
        base["configured"] = True
        base["reason"] = "TODO: WHOOP request failed."
        return base
    score = first_score(recovery)
    base.update(
        {
            "available": True,
            "configured": True,
            "reason": "",
            "recoveryScore": number(score, "recovery_score", as_int=True),
            "restingHr": number(score, "resting_heart_rate", as_int=True),
            "hrv": number(score, "hrv_rmssd_milli"),
            "sleepPerformance": number(first_score(sleep), "sleep_performance_percentage", as_int=True),
            "dayStrain": number(first_score(cycle), "strain"),
            "scored": (first_record(recovery) or {}).get("score_state") == "SCORED",
            "workouts": whoop_workouts(workouts),
        }
    )
    return base


def strava_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    base = empty_strava(day)
    if not configured("strava"):
        base["reason"] = "TODO: Strava tokens are not configured on the backend."
        return base
    token = access_token("strava")
    if not token:
        base["configured"] = True
        base["reason"] = "TODO: Strava token refresh failed."
        return base
    start, end = day_bounds(day, tz)
    payload = get_json(
        f"{STRAVA_API}/athlete/activities?after={int(start.timestamp())}&before={int(end.timestamp())}&per_page=50",
        token,
    )
    if not isinstance(payload, list):
        base["configured"] = True
        base["reason"] = "TODO: Strava request failed."
        return base
    base.update(
        {
            "available": True,
            "configured": True,
            "reason": "",
            "activities": [
                strava_activity(item)
                for item in payload
                if isinstance(item, dict) and isinstance(item.get("start_date"), str) and item.get("start_date")
            ],
        }
    )
    return base


def hevy_api_key() -> str:
    """Hevy Pro API key from HEVY_API_KEY or backend/.secrets/hevy.json ({"api_key": "..."}). Never returned."""
    if env("HEVY_API_KEY"):
        return env("HEVY_API_KEY")
    path = os.path.join(secrets_dir(), "hevy.json")
    try:
        with open(path, encoding="utf-8") as handle:
            stored = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return ""
    key = stored.get("api_key") if isinstance(stored, dict) else None
    return key.strip() if isinstance(key, str) else ""


def hevy_snapshot(day: str, tz: str | None = None) -> dict[str, Any]:
    base = empty_hevy(day)
    key = hevy_api_key()
    if not key:
        base["reason"] = "TODO: Set HEVY_API_KEY on the backend (Hevy Pro, hevy.com/settings)."
        return base
    base["configured"] = True
    start, end = day_bounds(day, tz)
    workouts: list[dict[str, Any]] = []
    for page in range(1, HEVY_MAX_PAGES + 1):
        payload = hevy_get(f"{HEVY_API}/v1/workouts?page={page}&pageSize={HEVY_PAGE_SIZE}", key)
        if not isinstance(payload, dict) or not isinstance(payload.get("workouts"), list):
            if page == 1:
                base["reason"] = "TODO: Hevy request failed. Check HEVY_API_KEY."
                return base
            break
        items = [item for item in payload["workouts"] if isinstance(item, dict)]
        parsed = [workout for workout in (hevy_workout(item) for item in items) if workout]
        workouts.extend(workout for workout in parsed if in_day(workout["start"], start, end))
        # Newest first: once a page reaches before the day, later pages are older still.
        if not items or any(before(workout["start"], start) for workout in parsed):
            break
        if page >= int(payload.get("page_count") or page):
            break
    base.update({"available": True, "reason": "", "workouts": workouts})
    return base


def hevy_get(url: str, key: str) -> Any:
    request = urllib.request.Request(url, headers={"api-key": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def hevy_workout(item: dict[str, Any]) -> dict[str, Any] | None:
    """One Hevy workout reduced to exercises and sets. No notes or description."""
    start = item.get("start_time")
    end = item.get("end_time")
    if not isinstance(start, str) or not start:
        return None
    exercises = []
    for exercise in item.get("exercises") or []:
        if not isinstance(exercise, dict):
            continue
        sets = []
        for entry in exercise.get("sets") or []:
            if not isinstance(entry, dict):
                continue
            reps = entry.get("reps")
            weight = entry.get("weight_kg")
            rpe = entry.get("rpe")
            duration = entry.get("duration_seconds")
            sets.append(
                {
                    "type": str(entry.get("type") or "normal"),
                    "reps": int(reps) if isinstance(reps, (int, float)) else None,
                    "weightKg": float(weight) if isinstance(weight, (int, float)) else None,
                    "rpe": float(rpe) if isinstance(rpe, (int, float)) else None,
                    "durationSec": float(duration) if isinstance(duration, (int, float)) else None,
                }
            )
        exercises.append(
            {
                "title": str(exercise.get("title") or ""),
                "templateId": str(exercise["exercise_template_id"]) if exercise.get("exercise_template_id") else None,
                "sets": sets,
            }
        )
    return {
        "id": str(item.get("id") or start),
        "title": str(item.get("title") or "Workout"),
        "start": iso_utc(start),
        "end": iso_utc(end if isinstance(end, str) and end else start),
        "exercises": exercises,
    }


def iso_utc(value: str) -> str:
    """Any ISO 8601 time as `YYYY-MM-DDTHH:MM:SSZ`, which the phone decodes."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return normalize_time(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
    return parsed.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=ZoneInfo("UTC"))
    except ValueError:
        return None


def in_day(value: str, start: datetime, end: datetime) -> bool:
    moment = parse_utc(value)
    return moment is not None and start <= moment < end


def before(value: str, start: datetime) -> bool:
    moment = parse_utc(value)
    return moment is not None and moment < start


def verify_whoop_signature(body: bytes, timestamp: str, signature: str, secret: str | None = None) -> bool:
    """HMAC-SHA256 of `{timestamp}{body}`, base64, using the webhook secret.

    WHOOP sends `X-WHOOP-Signature` and `X-WHOOP-Signature-Timestamp`.
    The check is a placeholder until a live subscription confirms the header format.
    """
    key = secret if secret is not None else (env("WHOOP_WEBHOOK_SECRET") or env("WHOOP_CLIENT_SECRET"))
    if not key or not timestamp or not signature:
        return False
    digest = hmac.new(key.encode(), timestamp.encode() + body, hashlib.sha256).digest()
    expected = base64.b64encode(digest).decode()
    return hmac.compare_digest(expected, signature.strip())


def strava_handshake(params: dict[str, str]) -> dict[str, str] | None:
    """Strava's subscription check. Event posts are not HMAC-signed by Strava."""
    verify = env("STRAVA_WEBHOOK_VERIFY_TOKEN")
    if params.get("hub.mode") != "subscribe" or not verify:
        return None
    if not hmac.compare_digest(params.get("hub.verify_token", ""), verify):
        return None
    challenge = params.get("hub.challenge", "")
    if not challenge:
        return None
    return {"hub.challenge": challenge}


def strava_event_allowed() -> bool:
    """Placeholder: accept event posts only after the verify token is configured.

    Strava does not sign each event. A future signature header can replace this.
    """
    return bool(env("STRAVA_WEBHOOK_VERIFY_TOKEN"))


def normalize_time(value: str) -> str:
    return re.sub(r"\.\d+", "", value)


def empty_whoop(day: str) -> dict[str, Any]:
    return {
        "available": False,
        "configured": False,
        "reason": "",
        "dayKey": day,
        "recoveryScore": None,
        "restingHr": None,
        "hrv": None,
        "sleepPerformance": None,
        "dayStrain": None,
        "scored": False,
        "workouts": [],
    }


def empty_strava(day: str) -> dict[str, Any]:
    return {"available": False, "configured": False, "reason": "", "dayKey": day, "activities": []}


def empty_hevy(day: str) -> dict[str, Any]:
    return {"available": False, "configured": False, "reason": "", "dayKey": day, "workouts": []}


def public_payload(payload: dict[str, Any]) -> dict[str, Any]:
    hidden = {"access_token", "refresh_token", "client_secret", "client_id", "api_key"}
    return {key: value for key, value in payload.items() if key not in hidden}


def local_zone(tz: str | None) -> ZoneInfo:
    """The phone's time zone, so a quest day ends at local midnight. Unknown names fall back to LA."""
    if not tz:
        return LA
    try:
        return ZoneInfo(tz)
    except (ValueError, KeyError):
        return LA


def day_bounds(day: str, tz: str | None = None) -> tuple[datetime, datetime]:
    zone = local_zone(tz)
    start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=zone)
    end = (start + timedelta(days=1)).replace(tzinfo=zone)
    return start, end


def whoop_collection(token: str, path: str, start: datetime, end: datetime) -> dict[str, Any] | None:
    query = urllib.parse.urlencode({"start": start.isoformat(), "end": end.isoformat(), "limit": 10})
    payload = get_json(f"{WHOOP_API}{path}?{query}", token)
    return payload if isinstance(payload, dict) else None


def get_json(url: str, token: str) -> Any:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def first_record(payload: dict[str, Any] | None) -> dict[str, Any] | None:
    if not payload:
        return None
    records = payload.get("records")
    if isinstance(records, list) and records and isinstance(records[0], dict):
        return records[0]
    return None


def first_score(payload: dict[str, Any] | None) -> dict[str, Any]:
    record = first_record(payload) or {}
    score = record.get("score")
    return score if isinstance(score, dict) else {}


def number(score: dict[str, Any], key: str, as_int: bool = False) -> int | float | None:
    value = score.get(key)
    if not isinstance(value, (int, float)):
        return None
    return int(value) if as_int else float(value)


def whoop_workouts(payload: dict[str, Any] | None) -> list[dict[str, Any]]:
    records = (payload or {}).get("records") if isinstance(payload, dict) else None
    if not isinstance(records, list):
        return []
    events = []
    for record in records:
        if not isinstance(record, dict):
            continue
        start = record.get("start")
        end = record.get("end")
        if not isinstance(start, str) or not isinstance(end, str):
            continue
        events.append(
            {
                "source": "whoop",
                "externalId": str(record.get("id") or start),
                "sport": str(record.get("sport_name") or "other"),
                "start": normalize_time(start),
                "end": normalize_time(end),
                "movingTimeSec": 0,
                "distanceMeters": None,
            }
        )
    return events


def strava_activity(item: dict[str, Any]) -> dict[str, Any]:
    start = normalize_time(str(item.get("start_date") or ""))
    moving = item.get("moving_time") if isinstance(item.get("moving_time"), (int, float)) else 0
    end = start
    if start.endswith("Z"):
        try:
            parsed = datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ")
            end = (parsed + timedelta(seconds=float(moving))).strftime("%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            end = start
    distance = item.get("distance") if isinstance(item.get("distance"), (int, float)) else None
    return {
        "source": "strava",
        "externalId": str(item.get("id") or start),
        "sport": str(item.get("type") or "other"),
        "start": normalize_time(start),
        "end": normalize_time(end),
        "movingTimeSec": float(moving),
        "distanceMeters": distance,
    }


def self_check() -> None:
    start, end = day_bounds("2026-10-02", "America/New_York")
    if start.isoformat() != "2026-10-02T00:00:00-04:00" or end.isoformat() != "2026-10-03T00:00:00-04:00":
        raise SystemExit("day bounds should follow the phone's time zone")
    if day_bounds("2026-10-02", "Not/AZone")[0].utcoffset() != day_bounds("2026-10-02")[0].utcoffset():
        raise SystemExit("an unknown time zone should fall back to Los Angeles")
    secret = "test-secret"
    body = b"{}"
    timestamp = "100"
    digest = base64.b64encode(hmac.new(secret.encode(), timestamp.encode() + body, hashlib.sha256).digest()).decode()
    if not verify_whoop_signature(body, timestamp, digest, secret):
        raise SystemExit("whoop signature should accept the matching digest")
    if verify_whoop_signature(body, timestamp, "not-the-signature", secret):
        raise SystemExit("whoop signature should reject a mismatch")
    if verify_whoop_signature(body, timestamp, digest, ""):
        raise SystemExit("whoop signature should reject a missing secret")
    url = whoop_authorize_url("public-client", "http://127.0.0.1:8787/v1/oauth/whoop/callback", "state")
    if "public-client" not in url or "client_secret" in url or secret in url:
        raise SystemExit("authorize URL leaked a secret")
    previous_verify = os.environ.pop("STRAVA_WEBHOOK_VERIFY_TOKEN", None)
    try:
        if strava_handshake({"hub.mode": "subscribe", "hub.verify_token": "x", "hub.challenge": "abc"}):
            raise SystemExit("strava handshake should fail without a verify token")
        os.environ["STRAVA_WEBHOOK_VERIFY_TOKEN"] = "verify-token"
        if strava_handshake({"hub.mode": "subscribe", "hub.verify_token": "nope", "hub.challenge": "abc"}):
            raise SystemExit("strava handshake should reject the wrong token")
        ok = strava_handshake({"hub.mode": "subscribe", "hub.verify_token": "verify-token", "hub.challenge": "abc"})
        if not ok or ok.get("hub.challenge") != "abc":
            raise SystemExit("strava handshake should echo the challenge")
        if not strava_event_allowed():
            raise SystemExit("strava events require the verify token")
    finally:
        if previous_verify is None:
            os.environ.pop("STRAVA_WEBHOOK_VERIFY_TOKEN", None)
        else:
            os.environ["STRAVA_WEBHOOK_VERIFY_TOKEN"] = previous_verify
    snapshot = public_payload(empty_whoop("2026-10-01"))
    blob = json.dumps(snapshot)
    for hidden in ("access_token", "refresh_token", "client_secret"):
        if hidden in blob:
            raise SystemExit("snapshot included a secret field")
    if snapshot["configured"] is not False or snapshot["available"] is not False:
        raise SystemExit("empty whoop snapshot should be disconnected")
    sample = {
        "id": "w1",
        "title": "Push",
        "description": "private note",
        "start_time": "2026-10-02T14:00:00+00:00",
        "end_time": "2026-10-02T15:05:30Z",
        "exercises": [
            {
                "title": "Bench Press (Barbell)",
                "exercise_template_id": "79D0BB3A",
                "notes": "private",
                "sets": [
                    {"type": "warmup", "weight_kg": 40, "reps": 10, "rpe": None},
                    {"type": "normal", "weight_kg": 80.5, "reps": 5, "rpe": 8},
                    {"type": "normal", "weight_kg": None, "reps": None},
                ],
            },
            {"title": "Splits", "exercise_template_id": None, "sets": [{"type": "normal", "duration_seconds": 90}]},
        ],
    }
    parsed = hevy_workout(sample)
    if not parsed or parsed["start"] != "2026-10-02T14:00:00Z" or parsed["end"] != "2026-10-02T15:05:30Z":
        raise SystemExit(f"hevy times should normalize to UTC Z, got {parsed}")
    bench = parsed["exercises"][0]
    if bench["templateId"] != "79D0BB3A" or [entry["type"] for entry in bench["sets"]] != ["warmup", "normal", "normal"]:
        raise SystemExit("hevy exercise should keep template id and set types")
    if bench["sets"][1] != {"type": "normal", "reps": 5, "weightKg": 80.5, "rpe": 8.0, "durationSec": None} or bench["sets"][2]["reps"] is not None:
        raise SystemExit(f"hevy sets should keep reps and kg, got {bench['sets']}")
    if parsed["exercises"][1]["sets"][0]["durationSec"] != 90.0 or parsed["exercises"][1]["templateId"] is not None:
        raise SystemExit("hevy timed sets should keep their duration")
    if "private" in json.dumps(parsed):
        raise SystemExit("hevy snapshot should drop notes and descriptions")
    if hevy_workout({"title": "no start"}) is not None:
        raise SystemExit("a hevy workout without a start time should be skipped")
    la_start, la_end = day_bounds("2026-10-02")
    if not in_day("2026-10-02T14:00:00Z", la_start, la_end) or in_day("2026-10-03T07:30:00Z", la_start, la_end):
        raise SystemExit("hevy day filter should follow local midnight")
    previous_key = os.environ.pop("HEVY_API_KEY", None)
    previous_dir = os.environ.get("SECRETS_DIR")
    os.environ["SECRETS_DIR"] = os.path.join(os.path.dirname(__file__), ".no-such-secrets")
    try:
        missing = hevy_snapshot("2026-10-02")
        if missing["configured"] or missing["available"] or "HEVY_API_KEY" not in missing["reason"]:
            raise SystemExit("hevy without a key should be disconnected with a TODO")
        os.environ["HEVY_API_KEY"] = "test-hevy-key"
        if hevy_api_key() != "test-hevy-key" or "test-hevy-key" in json.dumps(public_payload(empty_hevy("2026-10-02"))):
            raise SystemExit("hevy key should be read from the environment and never returned")
    finally:
        os.environ.pop("HEVY_API_KEY", None)
        if previous_key is not None:
            os.environ["HEVY_API_KEY"] = previous_key
        if previous_dir is None:
            os.environ.pop("SECRETS_DIR", None)
        else:
            os.environ["SECRETS_DIR"] = previous_dir
