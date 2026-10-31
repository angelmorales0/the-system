"""iOS app identity headers for private-API data requests."""

from __future__ import annotations

import os
import uuid
from typing import Callable

from .constants import IOS_APP_VERSION, IOS_BUILD_NUMBER, IOS_BUNDLE_NAME

_installation_id: str | None = None


def new_installation_id() -> str:
    """Uppercase UUID, matching the app's format."""
    return str(uuid.uuid4()).upper()


def get_installation_id(env: Callable[[str], str] | None = None) -> str:
    """Resolve a stable install id from env, else a per-process random UUID."""
    global _installation_id
    if _installation_id:
        return _installation_id
    lookup = env or (lambda name: os.environ.get(name, "").strip())
    value = lookup("WHOOP_INSTALLATION_ID") or lookup("WHOOP_PRIVATE_INSTALLATION_ID")
    _installation_id = value or new_installation_id()
    return _installation_id


def reset_installation_id_cache() -> None:
    """Test helper."""
    global _installation_id
    _installation_id = None


def device_timezone(env: Callable[[str], str] | None = None) -> str:
    lookup = env or (lambda name: os.environ.get(name, "").strip())
    value = lookup("WHOOP_TIMEZONE") or lookup("WHOOP_PRIVATE_TIMEZONE")
    if value and "/" in value:
        return value
    try:
        from zoneinfo import ZoneInfo
        from datetime import datetime

        # Prefer the host's local zone name when available.
        name = datetime.now().astimezone().tzinfo
        if name is not None:
            key = getattr(name, "key", None)
            if isinstance(key, str) and "/" in key:
                return key
        # Fall through if the local zone is a fixed offset.
        _ = ZoneInfo
    except Exception:
        pass
    return "America/Los_Angeles"


def device_headers(
    *,
    installation_id: str | None = None,
    timezone: str | None = None,
    env: Callable[[str], str] | None = None,
) -> dict[str, str]:
    """Headers the iOS app stamps on every data request (minus per-request telemetry)."""
    return {
        "user-agent": "iOS",
        "x-whoop-device-platform": "iOS",
        "x-whoop-ios-version": IOS_APP_VERSION,
        "x-whoop-ios-build-number": IOS_BUILD_NUMBER,
        "x-whoop-bundle-name": IOS_BUNDLE_NAME,
        "x-whoop-installation-identifier": installation_id or get_installation_id(env),
        "x-whoop-time-zone": timezone or device_timezone(env),
        "x-whoop-clock-format": "TWELVE_HOUR",
        "currency": "USD",
        "locale": "en_US",
        "accept-language": "en",
        "accept": "*/*",
        "priority": "u=3",
    }
