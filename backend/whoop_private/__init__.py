"""Unofficial WHOOP iOS (private) API client.

Adds Cognito auth and private BFF endpoints that the public developer API
(used by backend/integrations.py) does not expose. Does not replace or
rewire the existing OAuth WHOOP integration.
"""

from __future__ import annotations

from .catalog import ENDPOINTS, EndpointSpec, find_endpoints, unique_callables
from .client import WhoopPrivateClient
from .constants import EXISTING_PUBLIC_DEVELOPER_PATHS, TREND_METRICS
from .errors import (
    WhoopApiError,
    WhoopAuthError,
    WhoopAuthExpiredError,
    WhoopDecodeError,
    WhoopDestructiveBlocked,
    WhoopPrivateError,
)
from .tokens import TokenManager

__all__ = [
    "ENDPOINTS",
    "EXISTING_PUBLIC_DEVELOPER_PATHS",
    "EndpointSpec",
    "TREND_METRICS",
    "TokenManager",
    "WhoopApiError",
    "WhoopAuthError",
    "WhoopAuthExpiredError",
    "WhoopDecodeError",
    "WhoopDestructiveBlocked",
    "WhoopPrivateClient",
    "WhoopPrivateError",
    "find_endpoints",
    "self_check",
    "unique_callables",
]


def self_check() -> None:
    """Import-time / --check validation. Does not call the live WHOOP API."""
    from .tests import run_unit_checks

    run_unit_checks()
