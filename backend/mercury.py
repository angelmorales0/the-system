"""Mercury Read Only client and FIN aggregates.

The token is read from MERCURY_API_TOKEN only. It is never written to disk,
returned to iOS, or logged. Account numbers and routing numbers are dropped
before anything is stored.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from integrations import LA, secrets_dir

DEFAULT_BASE = "https://api.mercury.com/api/v1"
YTD_GOAL_USD = 500_000.0

# Undecided defaults. These are not a locked budget. Change the constants
# (or MERCURY_SETTLE_HOUR) when the real caps are chosen.
DAILY_SOFT_CAP_USD = 40.0
WEEKLY_SOFT_CAP_USD = 280.0
BALANCE_HARD_FLOOR_USD = 500.0
PACE_NORMAL = 0.75
PACE_CAUTION = 1.00
PACE_WARNING = 1.25
DEFAULT_SETTLE_HOUR = 21
PAGE_LIMIT = 1000
MAX_PAGES = 30

NECESSARY = {
    "Grocery",
    "Utilities",
    "Insurance",
    "Medical",
    "Taxes",
    "FacilitiesExpenses",
    "GovernmentServices",
    "InternetAndTelephone",
    "Legal",
    "Education",
    "FuelAndGas",
    "VehicleExpenses",
    "Fees",
    "ProfessionalServices",
    "Shipping",
    "OfficeSupplies",
}
DISCRETIONARY = {
    "Restaurants",
    "Entertainment",
    "AlcoholAndBars",
    "Retail",
    "FoodDelivery",
    "Clothing",
    "Gambling",
    "Lodging",
    "Airlines",
    "CarRental",
    "OtherTravel",
    "RideshareAndTaxis",
    "Electronics",
    "BooksAndNewspaper",
    "Memberships",
    "Conferences",
    "Software",
    "Advertising",
    "Charity",
    "Political",
    "Parking",
    "GroundTransportation",
    "Other",
}
TRANSFER_KINDS = {"internalTransfer", "treasuryTransfer"}
IGNORED_KINDS = {"interestPayment"}
DEAD_STATUSES = {"cancelled", "failed", "blocked", "reversed"}
INCOME_STATUSES = {"sent"}
TRANSACTION_EVENTS = {"transaction.created", "transaction.updated"}
BALANCE_EVENTS = {
    "checkingAccount.balance.updated",
    "savingsAccount.balance.updated",
    "creditAccount.balance.updated",
}
RENT_HINTS = ("rent", "landlord")
HIDDEN_KEYS = {
    "access_token",
    "refresh_token",
    "client_secret",
    "client_id",
    "accountnumber",
    "routingnumber",
    "secretkey",
    "authorization",
    "api_token",
    "token",
    "mercury_api_token",
}


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def configured() -> bool:
    return bool(env("MERCURY_API_TOKEN"))


def base_url() -> str:
    raw = env("MERCURY_API_BASE_URL").rstrip("/")
    if raw.startswith("https://") and " " not in raw and "@" not in raw:
        return raw
    return DEFAULT_BASE


def settle_hour() -> int:
    raw = env("MERCURY_SETTLE_HOUR")
    if not raw:
        return DEFAULT_SETTLE_HOUR
    try:
        hour = int(raw)
    except ValueError:
        return DEFAULT_SETTLE_HOUR
    return min(max(hour, 0), 23)


def ledger_path() -> str:
    return os.path.join(secrets_dir(), "mercury_ledger.json")


def category_map() -> dict[str, str]:
    path = env("MERCURY_CATEGORY_MAP")
    if not path:
        candidate = os.path.join(os.path.dirname(__file__), "mercury_categories.json")
        path = candidate if os.path.exists(candidate) else ""
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    allowed = {"necessary", "discretionary", "transfer", "income", "ignore"}
    return {str(key): str(value) for key, value in data.items() if str(value) in allowed}


def income_allowed(txn: dict[str, Any]) -> bool:
    pattern = env("MERCURY_INCOME_COUNTERPARTY_REGEX")
    if not pattern:
        return True
    try:
        return re.search(pattern, str(txn.get("counterpartyName") or ""), re.IGNORECASE) is not None
    except re.error:
        return True


def classify(txn: dict[str, Any], overrides: dict[str, str] | None = None) -> str:
    """Map one transaction to necessary, discretionary, income, transfer, or ignore.

    Negative amounts are money out. Positive amounts are credits. Internal
    transfers and interest never count as income or spend.
    """
    kind = str(txn.get("kind") or "")
    if kind in TRANSFER_KINDS:
        return "transfer"
    if kind in IGNORED_KINDS:
        return "ignore"
    status = str(txn.get("status") or "")
    if status in DEAD_STATUSES:
        return "ignore"
    try:
        amount = float(txn.get("amount") or 0)
    except (TypeError, ValueError):
        return "ignore"
    if amount > 0:
        if status and status not in INCOME_STATUSES:
            return "ignore"
        return "income" if income_allowed(txn) else "ignore"
    if amount == 0:
        return "ignore"
    category = category_name(txn)
    table = overrides if overrides is not None else category_map()
    mapped = table.get(category)
    if mapped:
        return mapped
    name = str(txn.get("counterpartyName") or "").lower()
    if any(hint in name for hint in RENT_HINTS):
        return "necessary"
    if category in NECESSARY:
        return "necessary"
    if category in DISCRETIONARY or not category:
        return "discretionary"
    return "discretionary"


def category_name(txn: dict[str, Any]) -> str:
    raw = txn.get("mercuryCategory")
    if isinstance(raw, dict):
        return str(raw.get("name") or "")
    if isinstance(raw, str):
        return raw
    merchant = txn.get("merchant")
    if isinstance(merchant, dict):
        nested = merchant.get("mercuryCategory")
        if isinstance(nested, str):
            return nested
    return ""


def local_day(value: str) -> str:
    text = value.strip()
    if not text:
        return ""
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            return value
        return ""
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(LA).date().isoformat()


def day_fraction(day: str, now: datetime) -> float:
    if now.tzinfo is None:
        now = now.replace(tzinfo=LA)
    else:
        now = now.astimezone(LA)
    if now.date().isoformat() > day:
        return 1.0
    if now.date().isoformat() < day:
        return 1 / 24
    elapsed = (now.hour * 60 + now.minute) / (24 * 60)
    return max(elapsed, 1 / 24)


def pace_state(
    discretionary_today: float,
    discretionary_7d: float,
    available_balance: float | None,
    fraction: float,
) -> str:
    """NORMAL / CAUTION / WARNING / CRITICAL from burn vs the soft caps.

    Thresholds are undecided defaults: 0.75, 1.00, and 1.25 times the
    elapsed slice of the daily cap, and the same cutoffs against the weekly cap.
    A checking balance under BALANCE_HARD_FLOOR_USD is at least WARNING.
    """
    daily_budget = DAILY_SOFT_CAP_USD * max(fraction, 1 / 24)
    daily_ratio = discretionary_today / daily_budget if daily_budget else 0.0
    weekly_ratio = discretionary_7d / WEEKLY_SOFT_CAP_USD if WEEKLY_SOFT_CAP_USD else 0.0
    ratio = max(daily_ratio, weekly_ratio)
    if ratio < PACE_NORMAL:
        state = "NORMAL"
    elif ratio < PACE_CAUTION:
        state = "CAUTION"
    elif ratio < PACE_WARNING:
        state = "WARNING"
    else:
        state = "CRITICAL"
    if available_balance is not None and available_balance < BALANCE_HARD_FLOOR_USD and state in {"NORMAL", "CAUTION"}:
        return "WARNING"
    return state


def is_settled(day: str, now: datetime | None = None) -> bool:
    current = now or datetime.now(LA)
    if current.tzinfo is None:
        current = current.replace(tzinfo=LA)
    else:
        current = current.astimezone(LA)
    if current.date().isoformat() > day:
        return True
    if current.date().isoformat() < day:
        return False
    return current.hour >= settle_hour()


def summarize(transactions: list[dict[str, Any]], day: str, accounts: list[dict[str, Any]] | None = None, now: datetime | None = None) -> dict[str, Any]:
    current = now or datetime.now(LA)
    overrides = category_map()
    year_start = f"{day[:4]}-01-01"
    try:
        day_date = datetime.strptime(day, "%Y-%m-%d").date()
    except ValueError:
        day_date = current.date()
    window_start = (day_date - timedelta(days=6)).isoformat()
    discretionary_today = 0.0
    necessary_today = 0.0
    discretionary_7d = 0.0
    income = 0.0
    for txn in transactions:
        if not isinstance(txn, dict):
            continue
        tag = classify(txn, overrides)
        when = local_day(str(txn.get("postedAt") or txn.get("createdAt") or ""))
        try:
            amount = float(txn.get("amount") or 0)
        except (TypeError, ValueError):
            continue
        if tag == "income" and year_start <= when <= day:
            income += amount
        if tag == "discretionary" and when == day:
            discretionary_today += abs(amount)
        if tag == "necessary" and when == day:
            necessary_today += abs(amount)
        if tag == "discretionary" and window_start <= when <= day:
            discretionary_7d += abs(amount)
    fraction = day_fraction(day, current)
    balance = lowest_available(accounts or [])
    state = pace_state(discretionary_today, discretionary_7d, balance, fraction)
    under = discretionary_today <= DAILY_SOFT_CAP_USD + 0.001
    return {
        "discretionarySpendUsd": round(discretionary_today, 2),
        "necessarySpendUsd": round(necessary_today, 2),
        "capUsd": DAILY_SOFT_CAP_USD,
        "discretionary7dUsd": round(discretionary_7d, 2),
        "paceState": state,
        "ytdIncomeUsd": round(income, 2),
        "ytdGoalUsd": YTD_GOAL_USD,
        "underCap": under,
        "settled": is_settled(day, current),
        "availableBalanceUsd": balance,
    }


def lowest_available(accounts: list[dict[str, Any]]) -> float | None:
    balances: list[float] = []
    for account in accounts:
        value = account.get("availableBalance")
        if isinstance(value, (int, float)):
            balances.append(float(value))
    if not balances:
        return None
    return min(balances)


def collect_cursor_pages(fetch: Callable[[str | None], tuple[list[dict[str, Any]], str | None]], max_pages: int = MAX_PAGES) -> list[dict[str, Any]]:
    """Walk Mercury's start_after / page.nextPage cursor. Stops on a repeat or an empty page."""
    items: list[dict[str, Any]] = []
    cursor: str | None = None
    seen: set[str] = set()
    for _ in range(max_pages):
        batch, next_page = fetch(cursor)
        items.extend(batch)
        if not next_page or next_page in seen or not batch:
            break
        seen.add(str(next_page))
        cursor = str(next_page)
    return items


def empty_snapshot(day: str, reason: str, *, configured_flag: bool) -> dict[str, Any]:
    return {
        "available": False,
        "configured": configured_flag,
        "reason": reason,
        "dayKey": day,
        "discretionarySpendUsd": 0,
        "necessarySpendUsd": 0,
        "capUsd": DAILY_SOFT_CAP_USD,
        "paceState": "NORMAL",
        "ytdIncomeUsd": 0,
        "ytdGoalUsd": YTD_GOAL_USD,
        "discretionary7dUsd": 0,
        "underCap": False,
        "settled": False,
        "synced": False,
    }


def snapshot(day: str, now: datetime | None = None) -> dict[str, Any]:
    if not configured():
        return empty_snapshot(
            day,
            "TODO: MERCURY_API_TOKEN is not set. Create a Read Only token in Mercury Settings, then Tokens.",
            configured_flag=False,
        )
    ledger = load_ledger()
    if not ledger.get("syncedAt"):
        return empty_snapshot(
            day,
            "TODO: Mercury token is set. POST /v1/integrations/mercury/sync has not run yet.",
            configured_flag=True,
        )
    summary = summarize(ledger.get("transactions") or [], day, ledger.get("accounts") or [], now)
    payload = {
        "available": True,
        "configured": True,
        "reason": "",
        "dayKey": day,
        "synced": True,
    }
    payload.update(summary)
    payload.pop("availableBalanceUsd", None)
    return public_view(payload)


def accounts_payload() -> dict[str, Any]:
    if not configured():
        return {"configured": False, "accounts": [], "page": {"nextPage": None}}
    ledger = load_ledger()
    accounts = [public_account(row) for row in ledger.get("accounts") or []]
    return {"configured": True, "accounts": accounts, "page": {"nextPage": None}}


def list_cached_transactions(limit: int = 100, start_after: str = "") -> dict[str, Any]:
    limit = max(1, min(int(limit), PAGE_LIMIT))
    rows = [public_transaction(row) for row in (load_ledger().get("transactions") or []) if isinstance(row, dict)]
    if start_after:
        index = next((i for i, row in enumerate(rows) if row.get("id") == start_after), None)
        rows = rows[index + 1 :] if index is not None else []
    page = rows[:limit]
    next_page = page[-1]["id"] if len(rows) > limit and page else None
    return {"transactions": page, "page": {"nextPage": next_page}}


def public_account(account: dict[str, Any]) -> dict[str, Any]:
    return public_view(
        {
            "id": account.get("id"),
            "name": account.get("name") or account.get("nickname") or "",
            "kind": account.get("kind") or "",
            "availableBalance": account.get("availableBalance"),
            "currentBalance": account.get("currentBalance"),
        }
    )


def public_transaction(txn: dict[str, Any]) -> dict[str, Any]:
    return public_view(slim_transaction(txn))


def public_view(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if str(key).lower() not in HIDDEN_KEYS}


def slim_transaction(txn: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": txn.get("id"),
        "amount": txn.get("amount"),
        "mercuryCategory": category_name(txn) or None,
        "kind": txn.get("kind"),
        "status": txn.get("status"),
        "postedAt": txn.get("postedAt"),
        "createdAt": txn.get("createdAt"),
        "counterpartyName": txn.get("counterpartyName") or "",
        "accountId": txn.get("accountId"),
    }


def load_ledger() -> dict[str, Any]:
    path = ledger_path()
    if not os.path.exists(path):
        return {"accounts": [], "transactions": [], "seenEventIds": [], "syncedAt": None}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"accounts": [], "transactions": [], "seenEventIds": [], "syncedAt": None}
    if not isinstance(data, dict):
        return {"accounts": [], "transactions": [], "seenEventIds": [], "syncedAt": None}
    data.setdefault("accounts", [])
    data.setdefault("transactions", [])
    data.setdefault("seenEventIds", [])
    data.setdefault("syncedAt", None)
    return data


def save_ledger(ledger: dict[str, Any]) -> None:
    os.makedirs(secrets_dir(), mode=0o700, exist_ok=True)
    path = ledger_path()
    blob = {
        "accounts": [public_account(row) for row in ledger.get("accounts") or [] if isinstance(row, dict)],
        "transactions": [slim_transaction(row) for row in ledger.get("transactions") or [] if isinstance(row, dict)],
        "seenEventIds": list(ledger.get("seenEventIds") or [])[-500:],
        "syncedAt": ledger.get("syncedAt"),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(blob, handle)
    os.chmod(path, 0o600)


def sync(now: datetime | None = None) -> dict[str, Any] | None:
    token = env("MERCURY_API_TOKEN")
    if not token:
        return None
    current = now or datetime.now(LA)
    year_start = f"{current.astimezone(LA).year}-01-01"
    end = (current.astimezone(LA).date() + timedelta(days=1)).isoformat()
    accounts = list_remote("/accounts", token, {}, "accounts")
    transactions = list_remote("/transactions", token, {"start": year_start, "end": end}, "transactions")
    if accounts is None or transactions is None:
        return None
    ledger = load_ledger()
    ledger["accounts"] = accounts
    ledger["transactions"] = transactions
    ledger["syncedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    save_ledger(ledger)
    return {"synced": True, "accounts": len(accounts), "transactions": len(transactions)}


def list_remote(path: str, token: str, query: dict[str, str], item_key: str) -> list[dict[str, Any]] | None:
    failed = {"failed": False}

    def fetch(cursor: str | None) -> tuple[list[dict[str, Any]], str | None]:
        params = dict(query)
        params["limit"] = str(PAGE_LIMIT)
        params["order"] = "asc"
        if cursor:
            params["start_after"] = cursor
        url = f"{base_url()}{path}?{urllib.parse.urlencode(params)}"
        payload = get_json(url, token)
        if not isinstance(payload, dict):
            failed["failed"] = True
            return [], None
        batch = payload.get(item_key)
        if not isinstance(batch, list):
            failed["failed"] = True
            return [], None
        rows = [row for row in batch if isinstance(row, dict)]
        page = payload.get("page") if isinstance(payload.get("page"), dict) else {}
        next_page = page.get("nextPage")
        return rows, str(next_page) if next_page else None

    items = collect_cursor_pages(fetch)
    if failed["failed"]:
        return None
    return items


def get_json(url: str, token: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def verify_signature(body: bytes, header: str, secret: str | None = None, now: float | None = None) -> bool:
    """Mercury-Signature: t=<unix>,v1=<hex hmac-sha256 of `timestamp.raw_body`>.

    Rejects a missing secret, a bad digest, and a timestamp skewed by more than 5 minutes.
    """
    key = secret if secret is not None else env("MERCURY_WEBHOOK_SECRET")
    if not key or not header:
        return False
    timestamp, signatures = parse_signature(header)
    if not timestamp or not signatures:
        return False
    try:
        stamp = int(timestamp)
    except ValueError:
        return False
    current = time.time() if now is None else now
    if abs(current - stamp) > 300:
        return False
    signed = timestamp.encode() + b"." + body
    expected = hmac.new(key.encode(), signed, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(expected, item) for item in signatures)


def parse_signature(header: str) -> tuple[str, list[str]]:
    timestamp = ""
    signatures: list[str] = []
    for part in header.split(","):
        piece = part.strip()
        if piece.startswith("t="):
            timestamp = piece[2:].strip()
        elif piece.startswith("v1="):
            signatures.append(piece[3:].strip())
    return timestamp, signatures


def event_name(event: dict[str, Any]) -> str:
    for key in ("type", "eventType", "event"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value
    resource = str(event.get("resourceType") or "")
    operation = str(event.get("operationType") or "")
    if resource == "transaction" and operation in {"create", "created"}:
        return "transaction.created"
    if resource == "transaction" and operation in {"update", "updated"}:
        return "transaction.updated"
    return ""


def ingest_event(event: dict[str, Any], fetch_transaction: Callable[[str], dict[str, Any] | None] | None = None) -> dict[str, Any]:
    """Apply a verified webhook. Transaction events refetch the resource when a fetcher is provided."""
    event_id = str(event.get("id") or "")
    ledger = load_ledger()
    seen = [str(item) for item in ledger.get("seenEventIds") or []]
    if event_id and event_id in seen:
        return {"ok": True, "duplicate": True}
    name = event_name(event)
    resource_id = str(event.get("resourceId") or "")
    if name in TRANSACTION_EVENTS:
        txn = embedded_transaction(event)
        if txn is None and resource_id and fetch_transaction is not None:
            txn = fetch_transaction(resource_id)
        if isinstance(txn, dict) and txn.get("id"):
            upsert_transaction(ledger, txn)
    elif name in BALANCE_EVENTS:
        apply_balance(ledger, event)
    if event_id:
        seen.append(event_id)
        ledger["seenEventIds"] = seen
    if ledger.get("transactions") or ledger.get("accounts") or ledger.get("syncedAt"):
        save_ledger(ledger)
    return {"ok": True, "duplicate": False, "event": name}


def embedded_transaction(event: dict[str, Any]) -> dict[str, Any] | None:
    for key in ("transaction", "resource", "data"):
        value = event.get(key)
        if isinstance(value, dict) and (value.get("id") or value.get("amount") is not None):
            if not value.get("id") and event.get("resourceId"):
                value = dict(value)
                value["id"] = event.get("resourceId")
            return value
    return None


def upsert_transaction(ledger: dict[str, Any], txn: dict[str, Any]) -> None:
    slim = slim_transaction(txn)
    if not slim.get("id"):
        return
    rows = [row for row in ledger.get("transactions") or [] if isinstance(row, dict) and row.get("id") != slim["id"]]
    rows.append(slim)
    ledger["transactions"] = rows


def apply_balance(ledger: dict[str, Any], event: dict[str, Any]) -> None:
    account_id = str(event.get("resourceId") or event.get("accountId") or "")
    available = event.get("availableBalance")
    current = event.get("currentBalance")
    resource = event.get("resource") if isinstance(event.get("resource"), dict) else {}
    if available is None:
        available = resource.get("availableBalance")
    if current is None:
        current = resource.get("currentBalance")
    if not account_id:
        account_id = str(resource.get("id") or "")
    if not account_id:
        return
    accounts = [row for row in ledger.get("accounts") or [] if isinstance(row, dict)]
    found = False
    for row in accounts:
        if row.get("id") == account_id:
            if isinstance(available, (int, float)):
                row["availableBalance"] = available
            if isinstance(current, (int, float)):
                row["currentBalance"] = current
            found = True
    if not found and isinstance(available, (int, float)):
        accounts.append({"id": account_id, "name": "", "kind": "", "availableBalance": available, "currentBalance": current})
    ledger["accounts"] = accounts


def pull_transaction(resource_id: str) -> dict[str, Any] | None:
    token = env("MERCURY_API_TOKEN")
    if not token or not resource_id:
        return None
    payload = get_json(f"{base_url()}/transaction/{urllib.parse.quote(resource_id)}", token)
    if isinstance(payload, dict) and payload.get("id"):
        return payload
    return None


def self_check() -> None:
    saved_token = os.environ.get("MERCURY_API_TOKEN")
    saved_secret = os.environ.get("MERCURY_WEBHOOK_SECRET")
    os.environ.pop("MERCURY_API_TOKEN", None)
    os.environ.pop("MERCURY_WEBHOOK_SECRET", None)
    try:
        _self_check_body()
    finally:
        if saved_token is None:
            os.environ.pop("MERCURY_API_TOKEN", None)
        else:
            os.environ["MERCURY_API_TOKEN"] = saved_token
        if saved_secret is None:
            os.environ.pop("MERCURY_WEBHOOK_SECRET", None)
        else:
            os.environ["MERCURY_WEBHOOK_SECRET"] = saved_secret


def _self_check_body() -> None:
    grocery = {"id": "g", "amount": -42.5, "mercuryCategory": "Grocery", "kind": "debitCardTransaction", "status": "sent", "postedAt": "2026-10-01T18:00:00Z"}
    dinner = {"id": "d", "amount": -18, "mercuryCategory": "Restaurants", "kind": "debitCardTransaction", "status": "sent", "postedAt": "2026-10-01T20:00:00Z"}
    if classify(grocery, {}) != "necessary":
        raise SystemExit("grocery should be necessary")
    if classify(dinner, {}) != "discretionary":
        raise SystemExit("restaurants should be discretionary")
    if classify(dinner, {"Restaurants": "necessary"}) != "necessary":
        raise SystemExit("category override should win")
    payroll = {"id": "p", "amount": 8000, "kind": "incomingDomesticWire", "status": "sent", "counterpartyName": "Payroll", "postedAt": "2026-06-01T15:00:00Z"}
    transfer = {"id": "t", "amount": 500, "kind": "internalTransfer", "status": "sent", "postedAt": "2026-06-02T15:00:00Z"}
    interest = {"id": "i", "amount": 3, "kind": "interestPayment", "status": "sent", "postedAt": "2026-06-03T15:00:00Z"}
    if classify(payroll, {}) != "income" or classify(transfer, {}) != "transfer" or classify(interest, {}) != "ignore":
        raise SystemExit("income rules should keep credits and drop transfers")
    noon = datetime(2026, 10, 1, 19, 0, tzinfo=timezone.utc)  # 12:00 America/Los_Angeles
    summary = summarize([grocery, dinner, payroll, transfer, interest], "2026-10-01", [{"availableBalance": 4000}], noon)
    if summary["necessarySpendUsd"] != 42.5 or summary["discretionarySpendUsd"] != 18:
        raise SystemExit(f"spend split wrong: {summary}")
    if summary["ytdIncomeUsd"] != 8000:
        raise SystemExit("YTD should count the credit and exclude the internal transfer")
    if summary["ytdGoalUsd"] != YTD_GOAL_USD:
        raise SystemExit("YTD goal should be 500000")
    if summary["underCap"] is not True:
        raise SystemExit("18 under 40 should be under the cap")
    full = 1.0
    if pace_state(20, 20, 4000, full) != "NORMAL":
        raise SystemExit("20/40 should be NORMAL")
    if pace_state(32, 32, 4000, full) != "CAUTION":
        raise SystemExit("32/40 should be CAUTION")
    if pace_state(42, 42, 4000, full) != "WARNING":
        raise SystemExit("42/40 should be WARNING")
    if pace_state(50, 50, 4000, full) != "CRITICAL":
        raise SystemExit("50/40 should be CRITICAL")
    if pace_state(0, 0, 100, full) != "WARNING":
        raise SystemExit("balance under the floor should be at least WARNING")
    pages = {
        None: ([{"id": "a"}], "a"),
        "a": ([{"id": "b"}], None),
    }
    walked = collect_cursor_pages(lambda cursor: pages[cursor])
    if [row["id"] for row in walked] != ["a", "b"]:
        raise SystemExit("pagination dropped a page")
    secret = "unit-webhook-secret"
    body = b'{"id":"evt-1"}'
    stamp = "1700000000"
    digest = hmac.new(secret.encode(), stamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    header = f"t={stamp},v1={digest}"
    if not verify_signature(body, header, secret, now=1700000000):
        raise SystemExit("mercury signature should accept the matching digest")
    if verify_signature(body, f"t={stamp},v1=deadbeef", secret, now=1700000000):
        raise SystemExit("mercury signature should reject a bad digest")
    if verify_signature(body, header, secret, now=1700000000 + 301):
        raise SystemExit("mercury signature should reject a stale timestamp")
    if verify_signature(body, header, "", now=1700000000):
        raise SystemExit("mercury signature should reject a missing secret")
    scratch = tempfile.mkdtemp()
    os.environ["SECRETS_DIR"] = scratch
    try:
        created = ingest_event(
            {
                "id": "evt-1",
                "type": "transaction.created",
                "resourceId": "d",
                "transaction": dinner,
            }
        )
        if created.get("duplicate"):
            raise SystemExit("first webhook should not be a duplicate")
        again = ingest_event({"id": "evt-1", "type": "transaction.created", "transaction": dinner})
        if not again.get("duplicate"):
            raise SystemExit("webhook event id should dedupe")
        stored = load_ledger().get("transactions") or []
        if not any(row.get("id") == "d" for row in stored):
            raise SystemExit("webhook should store the transaction summary")
        blob = json.dumps(load_ledger())
        if "accountNumber" in blob or "routingNumber" in blob:
            raise SystemExit("ledger stored a bank number")
        os.environ["MERCURY_API_TOKEN"] = "unit-test-token"
        pending = snapshot("2026-10-01", noon)
        if pending["synced"] or pending["available"]:
            raise SystemExit("a webhook before sync should not make the snapshot available")
        if "unit-test-token" in json.dumps(pending):
            raise SystemExit("snapshot leaked the token")
        os.environ.pop("MERCURY_API_TOKEN", None)
    finally:
        os.environ.pop("SECRETS_DIR", None)
    missing = snapshot("2026-10-01")
    if missing["configured"] or missing["synced"] or missing["available"]:
        raise SystemExit("missing token should stay unconfigured")
    if "TODO" not in missing["reason"]:
        raise SystemExit("missing token should explain the TODO")
    os.environ["MERCURY_API_TOKEN"] = "unit-test-token"
    os.environ["SECRETS_DIR"] = tempfile.mkdtemp()
    try:
        waiting = snapshot("2026-10-01")
    finally:
        os.environ.pop("SECRETS_DIR", None)
    blob = json.dumps(waiting)
    if "unit-test-token" in blob or "accountNumber" in blob:
        raise SystemExit("snapshot leaked a secret field")
    if waiting["configured"] is not True or waiting["synced"] is not False:
        raise SystemExit("a token without a sync should not look available")
    os.environ.pop("MERCURY_API_TOKEN", None)
    here = os.path.dirname(__file__)
    for name in ("mercury.py", ".env.example", "README.md"):
        text = open(os.path.join(here, name), encoding="utf-8").read()
        if re.search(r"secret-token:mercury_[A-Za-z0-9]{8,}", text):
            raise SystemExit(f"{name} contains a mercury token")
    source = open(__file__, encoding="utf-8").read()
    if re.search(r"secret-token:mercury_[A-Za-z0-9]{8,}", source):
        raise SystemExit("a mercury token was written into the source")
