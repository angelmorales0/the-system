"""Constants for the unofficial WHOOP iOS (private) API client."""

from __future__ import annotations

BASE_URL = "https://api.prod.whoop.com"
AUTH_URL = f"{BASE_URL}/auth-service/v3/whoop/"
API_VERSION = "7"
REQUEST_TIMEOUT_SEC = 30.0
REFRESH_SKEW_SEC = 60

# Captured from WHOOP iOS 5.52.0 (build 595097). Bump when the app ships a new version.
IOS_APP_VERSION = "5.52.0"
IOS_BUILD_NUMBER = "595097"
IOS_BUNDLE_NAME = "com.whoop.iphone"
IOS_VERSION_CAPTURED_AT = "2026-05"

COGNITO_USER_AGENT = (
    "aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 "
    "os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b"
)

# 25 trend metrics from the private progression-service surface.
TREND_METRICS: tuple[str, ...] = (
    "HRV",
    "RHR",
    "RECOVERY",
    "DAY_STRAIN",
    "CALORIES",
    "STEPS",
    "AVERAGE_HR",
    "HOURS_V_NEED",
    "HOURS_V_NEEDED_PERCENT",
    "TIME_IN_BED",
    "SLEEP_PERFORMANCE",
    "SLEEP_EFFICIENCY",
    "SLEEP_CONSISTENCY",
    "SLEEP_DEBT_POST",
    "RESTORATIVE_SLEEP",
    "HR_ZONES_1_3",
    "HR_ZONES_4_5",
    "RESPIRATORY_RATE",
    "STRENGTH_ACTIVITY_TIME",
    "STRESS",
    "STRESS_DURING_SLEEP",
    "STRESS_DURING_NON_STRAIN",
    "VO2_MAX",
    "BODY_COMPOSITION",
    "WEIGHT",
)

# Official developer API paths already used by backend/integrations.py + history.py.
# This private client does not wrap them.
EXISTING_PUBLIC_DEVELOPER_PATHS: tuple[str, ...] = (
    "/developer/v2/recovery",
    "/developer/v2/cycle",
    "/developer/v2/cycle/{cycleId}",
    "/developer/v2/cycle/{cycleId}/sleep",
    "/developer/v2/cycle/{cycleId}/recovery",
    "/developer/v2/activity/sleep",
    "/developer/v2/activity/sleep/{sleepId}",
    "/developer/v2/activity/workout",
    "/developer/v2/activity/workout/{workoutId}",
    "/developer/v2/user/profile/basic",
    "/developer/v2/user/measurement/body",
    "/developer/v2/user/access",
    "/developer/v1/activity-mapping/{activityV1Id}",
)
