"""Errors for the private WHOOP client."""

from __future__ import annotations


class WhoopPrivateError(Exception):
    """Base error for the private API client."""


class WhoopAuthError(WhoopPrivateError):
    """Sign-in, MFA, or token refresh failed."""


class WhoopAuthExpiredError(WhoopPrivateError):
    """Access token rejected with HTTP 401; caller should refresh and retry."""


class WhoopApiError(WhoopPrivateError):
    """Non-success HTTP response from a data endpoint."""

    def __init__(
        self,
        status: int,
        path: str,
        body: str = "",
        description: str | None = None,
    ) -> None:
        self.status = status
        self.path = path
        self.body = body
        self.description = description
        detail = description or body[:200] or "(empty body)"
        super().__init__(f"WHOOP {status} on {path}: {detail}")


class WhoopDecodeError(WhoopPrivateError):
    """Response JSON could not be decoded into the expected shape."""


class WhoopDestructiveBlocked(WhoopPrivateError):
    """A destructive write was attempted without confirm=True."""
