"""AWS Cognito auth via WHOOP's /auth-service/v3/whoop/ proxy.

The public developer OAuth flow in integrations.py cannot call private iOS
endpoints. This module signs in with email/password (and optional MFA) and
refreshes access tokens the same way the iOS app does.
"""

from __future__ import annotations

import json
import uuid
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from .constants import AUTH_URL, COGNITO_USER_AGENT, REQUEST_TIMEOUT_SEC
from .errors import WhoopAuthError


@dataclass
class CognitoTokens:
    access_token: str
    refresh_token: str
    id_token: str = ""
    expires_at_ms: int = 0


def decode_jwt_exp_ms(jwt: str) -> int:
    """Return the JWT `exp` claim as epoch milliseconds, or 0 on failure."""
    parts = jwt.split(".")
    if len(parts) < 2:
        return 0
    payload = parts[1]
    padding = "=" * ((4 - len(payload) % 4) % 4)
    try:
        import base64

        raw = base64.urlsafe_b64decode(payload + padding)
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return 0
    exp = data.get("exp") if isinstance(data, dict) else None
    return int(exp) * 1000 if isinstance(exp, (int, float)) else 0


def _cognito_headers(target: str) -> dict[str, str]:
    return {
        "content-type": "application/x-amz-json-1.1",
        "x-amz-target": f"AWSCognitoIdentityProviderService.{target}",
        "amz-sdk-request": "attempt=1; max=1",
        "amz-sdk-invocation-id": str(uuid.uuid4()),
        "user-agent": COGNITO_USER_AGENT,
        "accept": "*/*",
        "accept-encoding": "gzip, deflate, br",
        "accept-language": "en-US,en;q=0.9",
    }


def call_cognito(
    target: str,
    body: dict[str, Any],
    *,
    opener: Callable[..., Any] | None = None,
    timeout: float = REQUEST_TIMEOUT_SEC,
) -> dict[str, Any]:
    """POST one Cognito operation through WHOOP's auth proxy."""
    data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        AUTH_URL,
        data=data,
        method="POST",
        headers=_cognito_headers(target),
    )
    open_url = opener or urllib.request.urlopen
    try:
        with open_url(request, timeout=timeout) as response:
            text = response.read().decode("utf-8")
            status = getattr(response, "status", None) or response.getcode()
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        detail = err_body[:200]
        try:
            parsed = json.loads(err_body)
            if isinstance(parsed, dict):
                detail = f"{parsed.get('__type', 'error')}: {parsed.get('message', err_body)}"
        except json.JSONDecodeError:
            pass
        raise WhoopAuthError(f"Cognito {target} failed ({exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise WhoopAuthError(f"Cognito {target} network error: {exc}") from exc

    if int(status) >= 400:
        raise WhoopAuthError(f"Cognito {target} failed ({status}): {text[:200]}")
    try:
        parsed = json.loads(text) if text else {}
    except json.JSONDecodeError as exc:
        raise WhoopAuthError(f"Cognito {target} returned non-JSON: {text[:200]}") from exc
    if not isinstance(parsed, dict):
        raise WhoopAuthError(f"Cognito {target} returned unexpected payload type")
    return parsed


def tokens_from_auth(result: dict[str, Any], fallback_refresh: str = "") -> CognitoTokens:
    access = str(result.get("AccessToken") or "")
    if not access:
        raise WhoopAuthError("AuthenticationResult missing AccessToken")
    refresh = str(result.get("RefreshToken") or fallback_refresh or "")
    return CognitoTokens(
        access_token=access,
        refresh_token=refresh,
        id_token=str(result.get("IdToken") or ""),
        expires_at_ms=decode_jwt_exp_ms(access),
    )


def sign_in(
    email: str,
    password: str,
    *,
    mfa_code: str | None = None,
    mfa_prompt: Callable[[], str] | None = None,
    opener: Callable[..., Any] | None = None,
) -> CognitoTokens:
    """USER_PASSWORD_AUTH; handles SMS / TOTP / email OTP challenges."""
    if not email or not password:
        raise WhoopAuthError("WHOOP private email and password are required to sign in")
    init = call_cognito(
        "InitiateAuth",
        {
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": {"USERNAME": email, "PASSWORD": password},
            "ClientId": "",
        },
        opener=opener,
    )
    auth = init.get("AuthenticationResult")
    if isinstance(auth, dict) and auth.get("AccessToken"):
        return tokens_from_auth(auth)

    challenge = init.get("ChallengeName")
    if challenge in ("SMS_MFA", "SOFTWARE_TOKEN_MFA", "EMAIL_OTP"):
        session = init.get("Session")
        if not session:
            raise WhoopAuthError("Cognito MFA challenge missing Session token")
        code = (mfa_code or (mfa_prompt() if mfa_prompt else "") or "").strip()
        if not code:
            raise WhoopAuthError(
                f"Cognito requires {challenge}; pass mfa_code or mfa_prompt"
            )
        code_key = {
            "SMS_MFA": "SMS_MFA_CODE",
            "SOFTWARE_TOKEN_MFA": "SOFTWARE_TOKEN_MFA_CODE",
            "EMAIL_OTP": "EMAIL_OTP_CODE",
        }[str(challenge)]
        resp = call_cognito(
            "RespondToAuthChallenge",
            {
                "ClientId": "",
                "ChallengeName": challenge,
                "Session": session,
                "ChallengeResponses": {"USERNAME": email, code_key: code},
            },
            opener=opener,
        )
        auth = resp.get("AuthenticationResult")
        if not isinstance(auth, dict) or not auth.get("AccessToken"):
            raise WhoopAuthError(f"MFA verification did not return tokens: {resp!r}")
        return tokens_from_auth(auth)

    raise WhoopAuthError(f"Unexpected Cognito challenge: {challenge!r}")


def refresh_session(
    refresh_token: str,
    *,
    opener: Callable[..., Any] | None = None,
) -> CognitoTokens:
    """REFRESH_TOKEN_AUTH. Cognito usually does not rotate the refresh token."""
    if not refresh_token:
        raise WhoopAuthError("refresh token is empty")
    resp = call_cognito(
        "InitiateAuth",
        {
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": {"REFRESH_TOKEN": refresh_token},
            "ClientId": "",
        },
        opener=opener,
    )
    auth = resp.get("AuthenticationResult")
    if not isinstance(auth, dict) or not auth.get("AccessToken"):
        raise WhoopAuthError(f"Refresh did not return tokens: {resp!r}")
    return tokens_from_auth(auth, fallback_refresh=refresh_token)


def build_auth_request_headers(target: str = "InitiateAuth") -> dict[str, str]:
    """Public helper for unit tests that assert Cognito header fingerprints."""
    return _cognito_headers(target)
