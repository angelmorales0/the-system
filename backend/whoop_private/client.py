"""HTTP client for WHOOP's unofficial private iOS API.

Does not wrap the official /developer/v2/... endpoints already used by
backend/integrations.py. Those stay on the public OAuth token.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Mapping

from . import models
from .auth import build_auth_request_headers
from .catalog import (
    ENDPOINTS,
    EndpointSpec,
    find_endpoints,
    is_destructive,
    require_confirm,
    unique_callables,
)
from .constants import API_VERSION, BASE_URL, REQUEST_TIMEOUT_SEC, TREND_METRICS
from .device import device_headers
from .errors import (
    WhoopApiError,
    WhoopAuthExpiredError,
    WhoopDestructiveBlocked,
    WhoopPrivateError,
)
from .tokens import TokenManager


class WhoopPrivateClient:
    """Callable surface for the private iOS API (Cognito bearer + app headers)."""

    def __init__(
        self,
        tokens: TokenManager | None = None,
        *,
        base_url: str = BASE_URL,
        timeout: float = REQUEST_TIMEOUT_SEC,
        opener: Callable[..., Any] | None = None,
        auto_retry_auth: bool = True,
    ) -> None:
        self.tokens = tokens or TokenManager(opener=opener)
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.opener = opener or urllib.request.urlopen
        self.auto_retry_auth = auto_retry_auth

    # --- auth -------------------------------------------------------------

    def sign_in(self, email: str, password: str, *, mfa_code: str | None = None) -> str:
        self.tokens.sign_in(email, password, mfa_code=mfa_code)
        return self.tokens.access_token

    def ensure_auth(self, *, mfa_code: str | None = None) -> str:
        return self.tokens.ensure_signed_in(mfa_code=mfa_code)

    # --- generic transport ------------------------------------------------

    def request(
        self,
        method: str,
        path: str,
        *,
        query: Mapping[str, Any] | None = None,
        body: Any = None,
        confirm: bool = False,
        raw_response: bool = False,
    ) -> Any:
        """Send one authenticated request. Path should start with / and exclude apiVersion."""
        method_u = method.upper()
        if is_destructive(method_u, path) and not confirm:
            raise WhoopDestructiveBlocked(
                f"Refusing destructive {method_u} {path} without confirm=True"
            )
        return self._request(method_u, path, query=query, body=body, raw_response=raw_response)

    def call(
        self,
        spec: EndpointSpec,
        *,
        path_params: Mapping[str, Any] | None = None,
        query_params: Mapping[str, Any] | None = None,
        body: Any = None,
        confirm: bool = False,
    ) -> Any:
        require_confirm(spec, confirm)
        path, query = spec.render(path_params, query_params)
        return self._request(spec.method, path, query=query, body=body)

    def preview_destructive(
        self,
        method: str,
        path: str,
        *,
        body: Any = None,
        query: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Return a would-execute payload; does not call the network."""
        return {
            "preview": True,
            "will_execute": {
                "method": method.upper(),
                "path": path,
                "query": dict(query or {}),
                "body_summary": body,
            },
            "set_confirm_true_to_run": True,
            "destructive": is_destructive(method, path),
        }

    def raw_get(self, path: str, **query: Any) -> Any:
        return self.request("GET", path, query=query)

    def catalog(self) -> tuple[EndpointSpec, ...]:
        return ENDPOINTS

    def callables(self) -> tuple[EndpointSpec, ...]:
        return unique_callables()

    def find(self, **kwargs: Any) -> list[EndpointSpec]:
        return find_endpoints(**kwargs)

    # --- typed reads (private surfaces only) ------------------------------

    def stress(self, date: str) -> models.StressReading:
        """Intraday stress timeline for a calendar day."""
        raw = self.raw_get(f"/health-service/v2/stress-bff/{date}")
        return models.decode_stress(raw, date)

    def live_stress(self, date: str) -> models.LiveStressReading:
        """Current stress level (same endpoint as stress(), projected)."""
        raw = self.raw_get(f"/health-service/v2/stress-bff/{date}")
        return models.decode_live_stress(raw, date)

    def strain(self, date: str) -> models.StrainReading:
        """Day strain deep dive (SCORE_GAUGE + contributors)."""
        raw = self.raw_get("/home-service/v1/deep-dive/strain", date=date)
        return models.decode_strain(raw, date)

    def recovery_deep_dive(self, date: str) -> models.RecoveryReading:
        """Recovery deep dive BFF (richer than public /developer/v2/recovery)."""
        raw = self.raw_get("/home-service/v1/deep-dive/recovery", date=date)
        return models.decode_recovery(raw, date)

    def sleep_deep_dive(self, date: str) -> models.SleepDeepDive:
        """Last-night sleep stages + hypnogram (not in the public API)."""
        raw = self.raw_get("/home-service/v1/deep-dive/sleep/last-night", date=date)
        return models.decode_sleep_deep_dive(raw, date)

    def workout_detail(self, activity_id: str) -> models.WorkoutDetail:
        """Single workout cardio-details: HR curve, zones, strain, MSK."""
        raw = self.raw_get("/core-details-bff/v1/cardio-details", activityId=activity_id)
        return models.decode_workout_detail(raw, activity_id)

    def delete_workout(self, activity_id: str, *, confirm: bool = False) -> Any:
        """Destructive: delete an activity. Requires confirm=True."""
        path = "/core-details-bff/v1/cardio-details"
        if not confirm:
            return self.preview_destructive("DELETE", path, query={"activityId": activity_id})
        return self.request(
            "DELETE",
            path,
            query={"activityId": activity_id},
            confirm=True,
        )

    def trend(self, metric: str, end_date: str) -> models.TrendReading:
        metric_u = metric.upper()
        if metric_u not in TREND_METRICS:
            raise WhoopPrivateError(
                f"Unknown trend metric {metric!r}; expected one of {TREND_METRICS}"
            )
        raw = self.raw_get(f"/progression-service/v3/trends/{metric_u}", endDate=end_date)
        return models.decode_trend(raw, metric_u, end_date)

    def trends(self, end_date: str, metrics: tuple[str, ...] | None = None) -> list[models.TrendReading]:
        """Fetch trends for all 25 metrics (or a subset)."""
        chosen = metrics or TREND_METRICS
        return [self.trend(metric, end_date) for metric in chosen]

    def sleep_need(self) -> models.SleepNeedReading:
        raw = self.raw_get("/coaching-service/v2/sleepneed")
        return models.decode_sleep_need(raw)

    def live_hr(self) -> models.LiveHrReading:
        raw = self.raw_get("/health-tab-bff/v1/health-tab")
        return models.decode_live_hr(raw)

    def live_user_state(self) -> models.LiveUserState:
        raw = self.raw_get("/activities-service/v1/user-state")
        return models.decode_user_state(raw)

    def strength_prs(
        self,
        *,
        start_date: str | None = None,
        end_date: str | None = None,
        offset: int | None = None,
    ) -> Any:
        query: dict[str, Any] = {}
        if start_date:
            query["startDate"] = start_date
        if end_date:
            query["endDate"] = end_date
        if offset is not None:
            query["offset"] = offset
        return self.request("GET", "/weightlifting-service/v3/prs", query=query)

    def strength_progression(self, exercise_id: str, end_date: str) -> Any:
        return self.raw_get(
            f"/progression-service/v3/exercise/{exercise_id}",
            endDate=end_date,
        )

    def strength_exercise_history(self, exercise_id: str) -> Any:
        return self.raw_get(f"/weightlifting-service/v3/exercise/{exercise_id}/exercise_history")

    def journal_behaviors(self, date: str) -> Any:
        return self.raw_get(f"/journal-service/v2/journals/behaviors/user/{date}")

    def journal_drafts(self, date: str) -> Any:
        return self.raw_get(f"/journal-service/v3/journals/drafts/mobile/{date}")

    def journal_home_tile(self, date: str) -> Any:
        return self.raw_get("/journal-service/v3/journals/home-tile", date=date)

    def behavior_impact(self) -> Any:
        return self.raw_get("/behavior-impact-service/v1/impact")

    def behavior_impact_summary(self, date: str) -> Any:
        return self.raw_get(f"/behavior-impact-service/v1/impact/summary-card/{date}")

    def journal_autopop(self, entry_id: str, *, confirm: bool = False, body: Any = None) -> Any:
        """Destructive-ish write: journal autopop. Requires confirm=True to execute."""
        path = f"/autopop-service/v1/autopop/JOURNAL/{entry_id}"
        if not confirm:
            return self.preview_destructive("PUT", path, body=body)
        return self.request("PUT", path, body=body if body is not None else {}, confirm=True)

    # --- internals --------------------------------------------------------

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: Mapping[str, Any] | None = None,
        body: Any = None,
        raw_response: bool = False,
        _retried: bool = False,
    ) -> Any:
        if not path.startswith("/"):
            path = "/" + path
        token = self.tokens.get_token() if self.tokens.access_token or self.tokens.refresh_token else self.tokens.ensure_signed_in()
        url = self._build_url(path, query)
        headers = {
            **device_headers(),
            "authorization": f"Bearer {token}",
        }
        data: bytes | None = None
        if body is not None:
            headers["content-type"] = "application/json"
            data = json.dumps(body).encode("utf-8")

        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self.opener(request, timeout=self.timeout) as response:
                status = getattr(response, "status", None) or response.getcode()
                payload = response.read()
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            if exc.code == 401 and self.auto_retry_auth and not _retried:
                # Force a Cognito refresh (do not set expires_at=0 — TokenManager
                # treats a missing/zero expiry as "assume fresh").
                try:
                    self.tokens.force_refresh()
                except Exception as refresh_exc:  # noqa: BLE001 — surface as auth expired
                    raise WhoopAuthExpiredError(
                        f"401 on {path} and refresh failed: {refresh_exc}"
                    ) from refresh_exc
                return self._request(
                    method,
                    path,
                    query=query,
                    body=body,
                    raw_response=raw_response,
                    _retried=True,
                )
            if exc.code == 401:
                raise WhoopAuthExpiredError(f"401 on {path}") from exc
            raise WhoopApiError(exc.code, path, err_body, _error_description(err_body)) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise WhoopApiError(0, path, str(exc), str(exc)) from exc

        if int(status) == 204:
            return None
        if int(status) >= 400:
            text = payload.decode("utf-8", errors="replace")
            raise WhoopApiError(int(status), path, text, _error_description(text))
        if raw_response:
            return payload
        if not payload:
            return None
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise WhoopApiError(int(status), path, payload[:200].decode("utf-8", errors="replace")) from exc

    def _build_url(self, path: str, query: Mapping[str, Any] | None) -> str:
        params: dict[str, str] = {"apiVersion": API_VERSION}
        for key, value in (query or {}).items():
            if value is None:
                continue
            params[str(key)] = str(value)
        return f"{self.base_url}{path}?{urllib.parse.urlencode(params)}"


def _error_description(text: str) -> str | None:
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    for key in ("error_description", "message", "error", "__type"):
        value = parsed.get(key)
        if isinstance(value, str) and value:
            return value
    return None


# Re-export for tests / importers that want header builders without digging.
cognito_headers = build_auth_request_headers
