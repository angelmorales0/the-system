"""Load/store Cognito tokens for the private client.

Uses backend/.secrets/whoop_private.json (gitignored) and WHOOP_PRIVATE_* env
vars. Does not touch the public OAuth tokens in whoop.json / WHOOP_ACCESS_TOKEN.
"""

from __future__ import annotations

import json
import os
import threading
import time
from typing import Any, Callable

from .auth import CognitoTokens, decode_jwt_exp_ms, refresh_session, sign_in
from .constants import REFRESH_SKEW_SEC
from .errors import WhoopAuthError


def secrets_dir() -> str:
    return os.environ.get(
        "SECRETS_DIR",
        os.path.join(os.path.dirname(os.path.dirname(__file__)), ".secrets"),
    )


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def _token_path() -> str:
    return os.path.join(secrets_dir(), "whoop_private.json")


def load_tokens() -> dict[str, Any]:
    tokens: dict[str, Any] = {}
    path = _token_path()
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as handle:
                stored = json.load(handle)
            if isinstance(stored, dict):
                tokens.update(stored)
        except (OSError, json.JSONDecodeError):
            tokens = {}
    # Prefer private-prefixed env; accept totem-style aliases for convenience.
    access = (
        env("WHOOP_PRIVATE_ACCESS_TOKEN")
        or env("WHOOP_IOS_BEARER_TOKEN")
        or env("WHOOP_IOS_ACCESS_TOKEN")
    )
    refresh = env("WHOOP_PRIVATE_REFRESH_TOKEN") or env("WHOOP_COGNITO_REFRESH_TOKEN")
    email = env("WHOOP_PRIVATE_EMAIL") or env("WHOOP_EMAIL")
    if access:
        tokens["access_token"] = access
    if refresh:
        tokens["refresh_token"] = refresh
    if email:
        tokens["email"] = email
    if env("WHOOP_PRIVATE_EXPIRES_AT"):
        try:
            tokens["expires_at"] = int(env("WHOOP_PRIVATE_EXPIRES_AT"))
        except ValueError:
            pass
    elif access and "expires_at" not in tokens:
        exp_ms = decode_jwt_exp_ms(access)
        if exp_ms:
            tokens["expires_at"] = exp_ms // 1000
    return tokens


def save_tokens(tokens: dict[str, Any]) -> None:
    os.makedirs(secrets_dir(), mode=0o700, exist_ok=True)
    path = _token_path()
    payload = {
        "access_token": tokens.get("access_token", ""),
        "refresh_token": tokens.get("refresh_token", ""),
        "id_token": tokens.get("id_token", ""),
        "expires_at": tokens.get("expires_at", 0),
        "email": tokens.get("email", ""),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.chmod(path, 0o600)


def credentials_from_env() -> tuple[str, str]:
    email = env("WHOOP_PRIVATE_EMAIL") or env("WHOOP_EMAIL")
    password = env("WHOOP_PRIVATE_PASSWORD") or env("WHOOP_PASSWORD")
    return email, password


class TokenManager:
    """Single-flight access-token refresh for the private API."""

    def __init__(
        self,
        *,
        email: str = "",
        access_token: str = "",
        refresh_token: str = "",
        expires_at: int = 0,
        refresh_skew_sec: int = REFRESH_SKEW_SEC,
        persist: bool = True,
        opener: Callable[..., Any] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        stored = load_tokens()
        self.email = email or str(stored.get("email") or "")
        self.access_token = access_token or str(stored.get("access_token") or "")
        self.refresh_token = refresh_token or str(stored.get("refresh_token") or "")
        self.expires_at = expires_at or int(stored.get("expires_at") or 0)
        if self.access_token and not self.expires_at:
            self.expires_at = decode_jwt_exp_ms(self.access_token) // 1000
        self.refresh_skew_sec = refresh_skew_sec
        self.persist = persist
        self.opener = opener
        self.clock = clock or time.time
        self._lock = threading.Lock()
        self._refreshing: threading.Event | None = None

    def is_fresh(self) -> bool:
        if not self.access_token:
            return False
        if not self.expires_at:
            return True
        return self.clock() < self.expires_at - self.refresh_skew_sec

    def get_token(self) -> str:
        if self.is_fresh():
            return self.access_token
        with self._lock:
            if self.is_fresh():
                return self.access_token
            self._do_refresh()
            return self.access_token

    def ensure_signed_in(self, *, mfa_code: str | None = None) -> str:
        """Use stored tokens, else sign in with email/password from env/config."""
        if self.refresh_token or self.access_token:
            return self.get_token()
        email, password = credentials_from_env()
        email = self.email or email
        if not email or not password:
            raise WhoopAuthError(
                "No WHOOP private tokens and no WHOOP_PRIVATE_EMAIL / "
                "WHOOP_PRIVATE_PASSWORD (or WHOOP_EMAIL / WHOOP_PASSWORD)"
            )
        tokens = sign_in(email, password, mfa_code=mfa_code, opener=self.opener)
        self._apply(tokens, email=email)
        return self.access_token

    def sign_in(self, email: str, password: str, *, mfa_code: str | None = None) -> CognitoTokens:
        tokens = sign_in(email, password, mfa_code=mfa_code, opener=self.opener)
        self._apply(tokens, email=email)
        return tokens

    def force_refresh(self) -> str:
        """Refresh now, even if the access token still looks fresh."""
        self._do_refresh()
        return self.access_token

    def _do_refresh(self) -> None:
        if not self.refresh_token:
            # Fall back to password sign-in when only credentials exist.
            email, password = credentials_from_env()
            email = self.email or email
            if email and password:
                tokens = sign_in(email, password, opener=self.opener)
                self._apply(tokens, email=email)
                return
            raise WhoopAuthError("No refresh token available for WHOOP private auth")
        tokens = refresh_session(self.refresh_token, opener=self.opener)
        self._apply(tokens, email=self.email)

    def _apply(self, tokens: CognitoTokens, *, email: str = "") -> None:
        self.access_token = tokens.access_token
        if tokens.refresh_token:
            self.refresh_token = tokens.refresh_token
        self.expires_at = (tokens.expires_at_ms // 1000) if tokens.expires_at_ms else 0
        if email:
            self.email = email
        if self.persist:
            save_tokens(
                {
                    "access_token": self.access_token,
                    "refresh_token": self.refresh_token,
                    "id_token": tokens.id_token,
                    "expires_at": self.expires_at,
                    "email": self.email,
                }
            )
