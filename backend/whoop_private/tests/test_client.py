"""Unit tests for whoop_private. No live WHOOP API calls."""

from __future__ import annotations

import base64
import json
import unittest
from io import BytesIO
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request

from whoop_private.auth import build_auth_request_headers, decode_jwt_exp_ms, tokens_from_auth
from whoop_private.catalog import ENDPOINTS, EndpointSpec, is_destructive, unique_callables
from whoop_private.client import WhoopPrivateClient
from whoop_private.constants import API_VERSION, EXISTING_PUBLIC_DEVELOPER_PATHS, TREND_METRICS
from whoop_private.device import device_headers, reset_installation_id_cache
from whoop_private.errors import WhoopDestructiveBlocked
from whoop_private.models import (
    decode_live_hr,
    decode_recovery,
    decode_sleep_need,
    decode_strain,
    decode_stress,
    decode_user_state,
    decode_workout_detail,
)
from whoop_private.tokens import TokenManager

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def _load(name: str) -> Any:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class FakeHTTPResponse:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self.status = status

    def read(self) -> bytes:
        return self._body

    def getcode(self) -> int:
        return self.status

    def __enter__(self) -> FakeHTTPResponse:
        return self

    def __exit__(self, *args: object) -> None:
        return None


class RecordingOpener:
    def __init__(self, responses: list[FakeHTTPResponse | Exception] | None = None) -> None:
        self.calls: list[Request] = []
        self._responses = list(responses or [])

    def __call__(self, request: Request, timeout: float = 0) -> FakeHTTPResponse:
        self.calls.append(request)
        if not self._responses:
            return FakeHTTPResponse(b"{}", 200)
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def _header(request: Request, name: str) -> str | None:
    # urllib title-cases via get_header; Request.headers keys vary by Python version.
    titled = "-".join(part.capitalize() for part in name.split("-"))
    value = request.get_header(titled)
    if value is not None:
        return value
    for key, val in request.headers.items():
        if key.lower() == name.lower():
            return val
    return None


class CatalogTests(unittest.TestCase):
    def test_catalog_has_311_rows(self) -> None:
        self.assertEqual(len(ENDPOINTS), 311)

    def test_unique_callables_cover_private_surfaces(self) -> None:
        paths = {spec.path_template for spec in unique_callables()}
        self.assertIn("/health-service/v2/stress-bff/{date}", paths)
        self.assertIn("/home-service/v1/deep-dive/strain", paths)
        self.assertIn("/core-details-bff/v1/cardio-details", paths)
        self.assertFalse(any(path.startswith("/developer/") for path in paths))
        for path in EXISTING_PUBLIC_DEVELOPER_PATHS:
            self.assertNotIn(path, paths)

    def test_path_templating(self) -> None:
        spec = EndpointSpec(
            method="GET",
            path_template="/health-service/v2/stress-bff/{date}",
            query_template={},
        )
        path, query = spec.render({"date": "2026-05-24"})
        self.assertEqual(path, "/health-service/v2/stress-bff/2026-05-24")
        self.assertEqual(query, {})

        spec2 = EndpointSpec(
            method="GET",
            path_template="/core-details-bff/v1/cardio-details",
            query_template={"activityId": "{uuid}"},
        )
        path2, query2 = spec2.render({"uuid": "abc-123"})
        self.assertEqual(path2, "/core-details-bff/v1/cardio-details")
        self.assertEqual(query2["activityId"], "abc-123")

    def test_destructive_flags(self) -> None:
        self.assertTrue(is_destructive("DELETE", "/core-details-bff/v1/cardio-details"))
        self.assertTrue(is_destructive("PUT", "/autopop-service/v1/autopop/JOURNAL/1"))
        self.assertFalse(is_destructive("GET", "/health-service/v2/stress-bff/2026-05-24"))


class AuthHeaderTests(unittest.TestCase):
    def test_cognito_headers(self) -> None:
        headers = build_auth_request_headers("InitiateAuth")
        self.assertEqual(headers["content-type"], "application/x-amz-json-1.1")
        self.assertEqual(
            headers["x-amz-target"],
            "AWSCognitoIdentityProviderService.InitiateAuth",
        )
        self.assertIn("aws-sdk-swift", headers["user-agent"])
        self.assertIn("amz-sdk-invocation-id", headers)

    def test_device_headers(self) -> None:
        reset_installation_id_cache()
        headers = device_headers(installation_id="AAAA", timezone="America/New_York")
        self.assertEqual(headers["user-agent"], "iOS")
        self.assertEqual(headers["x-whoop-device-platform"], "iOS")
        self.assertEqual(headers["x-whoop-installation-identifier"], "AAAA")
        self.assertEqual(headers["x-whoop-time-zone"], "America/New_York")

    def test_jwt_exp_and_tokens_from_auth(self) -> None:
        payload = base64.urlsafe_b64encode(b'{"exp":1700000000}').decode().rstrip("=")
        jwt = f"aaa.{payload}.sig"
        self.assertEqual(decode_jwt_exp_ms(jwt), 1700000000 * 1000)
        tokens = tokens_from_auth(
            {
                "AccessToken": jwt,
                "RefreshToken": "refresh",
                "IdToken": "id",
                "ExpiresIn": 86400,
            }
        )
        self.assertEqual(tokens.refresh_token, "refresh")
        self.assertEqual(tokens.expires_at_ms, 1700000000 * 1000)


class RequestBuildingTests(unittest.TestCase):
    def test_api_version_and_auth_header(self) -> None:
        opener = RecordingOpener([FakeHTTPResponse(b'{"ok":true}', 200)])
        tokens = TokenManager(
            access_token="tok123",
            refresh_token="ref",
            expires_at=9_999_999_999,
            persist=False,
            opener=opener,
        )
        client = WhoopPrivateClient(tokens=tokens, opener=opener)
        result = client.raw_get("/health-service/v2/stress-bff/2026-05-24")
        self.assertEqual(result, {"ok": True})
        self.assertEqual(len(opener.calls), 1)
        req = opener.calls[0]
        self.assertIn(f"apiVersion={API_VERSION}", req.full_url)
        self.assertEqual(_header(req, "Authorization"), "Bearer tok123")
        self.assertEqual(_header(req, "User-Agent"), "iOS")
        self.assertEqual(_header(req, "X-Whoop-Device-Platform"), "iOS")

    def test_destructive_blocked_without_confirm(self) -> None:
        opener = RecordingOpener()
        tokens = TokenManager(
            access_token="tok",
            refresh_token="ref",
            expires_at=9_999_999_999,
            persist=False,
            opener=opener,
        )
        client = WhoopPrivateClient(tokens=tokens, opener=opener)
        with self.assertRaises(WhoopDestructiveBlocked):
            client.request(
                "DELETE",
                "/core-details-bff/v1/cardio-details",
                query={"activityId": "x"},
            )
        preview = client.delete_workout("x", confirm=False)
        self.assertTrue(preview["preview"])
        self.assertEqual(len(opener.calls), 0)

    def test_401_triggers_refresh_retry(self) -> None:
        payload = base64.urlsafe_b64encode(b'{"exp":9999999999}').decode().rstrip("=")
        new_access = f"aaa.{payload}.sig"
        refresh_body = json.dumps(
            {
                "AuthenticationResult": {
                    "AccessToken": new_access,
                    "IdToken": "id",
                    "ExpiresIn": 86400,
                    "TokenType": "Bearer",
                }
            }
        ).encode()
        err = HTTPError(
            url="https://api.prod.whoop.com/x",
            code=401,
            msg="Unauthorized",
            hdrs=None,  # type: ignore[arg-type]
            fp=BytesIO(b'{"message":"Access Token has expired"}'),
        )
        opener = RecordingOpener(
            [
                err,
                FakeHTTPResponse(refresh_body, 200),
                FakeHTTPResponse(b'{"state":"idle"}', 200),
            ]
        )
        # Token looks fresh so the first get_token() does not refresh preemptively.
        tokens = TokenManager(
            access_token="expired-but-unexpired-claim",
            refresh_token="refresh-token",
            expires_at=9_999_999_999,
            persist=False,
            opener=opener,
        )
        client = WhoopPrivateClient(tokens=tokens, opener=opener)
        result = client.live_user_state()
        self.assertEqual(result.state, "idle")
        self.assertEqual(len(opener.calls), 3)
        self.assertEqual(_header(opener.calls[2], "Authorization"), f"Bearer {new_access}")


class DecodeTests(unittest.TestCase):
    def test_stress_fixture(self) -> None:
        reading = decode_stress(_load("stress.json"), "2026-05-24")
        self.assertEqual(reading.current_level, 0.6)
        self.assertEqual(reading.peak_level, 1.2)
        self.assertEqual(reading.min_level, 0.4)
        self.assertEqual(reading.calibration_state, "CALIBRATED")
        self.assertEqual(len(reading.timeline), 3)
        self.assertEqual(reading.timeline[0].started_at, "2026-05-24T09:00:00")

    def test_strain_and_recovery_fixtures(self) -> None:
        strain = decode_strain(_load("strain.json"), "2026-05-24")
        self.assertEqual(strain.score, 12.4)
        self.assertEqual(strain.workouts_count, 2)
        self.assertEqual(strain.steps, 8432)
        self.assertEqual(strain.zone_1_3_ms, (1 * 60 + 20) * 60 * 1000)
        recovery = decode_recovery(_load("recovery.json"), "2026-05-24")
        self.assertEqual(recovery.score, 67)
        self.assertEqual(recovery.hrv, 62)
        self.assertEqual(recovery.resting_hr, 51)

    def test_sleep_need_user_state_workout(self) -> None:
        need = decode_sleep_need(_load("sleep_need.json"))
        self.assertEqual(need.recommended_time_in_bed, "8:00")
        self.assertEqual(need.baseline_minutes, 450)
        self.assertEqual(need.debt_minutes, 60)
        self.assertTrue(need.smart_alarm_eligible)
        state = decode_user_state(_load("user_state.json"))
        self.assertEqual(state.state, "idle")
        workout = decode_workout_detail(_load("cardio_details.json"), "act-1")
        self.assertEqual(workout.activity_id, "act-1")
        self.assertEqual(workout.strain, 11.2)
        self.assertEqual(workout.hr_curve_point_count, 4)
        self.assertEqual(workout.msk.get("muscular_load"), 420)

    def test_missing_fields_tolerant(self) -> None:
        reading = decode_stress({}, "2026-05-24")
        self.assertIsNone(reading.current_level)
        self.assertEqual(reading.timeline, [])
        hr = decode_live_hr({"show_live_hr": False})
        self.assertIsNone(hr.current_bpm)
        self.assertFalse(hr.is_recording)

    def test_trend_metrics_count(self) -> None:
        self.assertEqual(len(TREND_METRICS), 25)


if __name__ == "__main__":
    unittest.main()
