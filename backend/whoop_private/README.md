# WHOOP private (iOS) API client

Python client for WHOOP’s **unofficial** private iOS API at `api.prod.whoop.com`. It lives next to the existing FastAPI quest stub and does **not** wire into any UI, screens, or quest features.

## What this is / is not

- **Unofficial.** Captured from the WHOOP iOS app’s traffic. Shapes and paths can change when the app updates. Using it may violate WHOOP’s Terms of Service. Use only with **your own** account.
- **Not** a replacement for the official developer API already used by `backend/integrations.py` (OAuth + `/developer/v2/recovery|cycle|sleep|workout`). Those stay as they are.
- **Adds** Cognito email/password auth (required for private BFFs) and callable coverage for the private surfaces the public API does not expose (stress, deep dives, live HR/state, trends, journal, strength PRs, …).

## Configure credentials

Secrets come from the environment or `backend/.secrets/whoop_private.json` (gitignored). Never commit tokens or passwords.

```bash
# Cognito sign-in (private API only — separate from WHOOP_CLIENT_ID OAuth)
export WHOOP_PRIVATE_EMAIL='you@example.com'
export WHOOP_PRIVATE_PASSWORD='…'

# Optional: reuse an existing Cognito session instead of password sign-in
export WHOOP_PRIVATE_ACCESS_TOKEN='…'      # JWT access token
export WHOOP_PRIVATE_REFRESH_TOKEN='…'     # Cognito refresh (JWE)

# Optional identity headers
export WHOOP_INSTALLATION_ID='…'           # uppercase UUID; stable per install
export WHOOP_TIMEZONE='America/Los_Angeles'
```

Aliases accepted: `WHOOP_EMAIL` / `WHOOP_PASSWORD`, `WHOOP_IOS_BEARER_TOKEN`, `WHOOP_COGNITO_REFRESH_TOKEN`.

Public OAuth vars (`WHOOP_CLIENT_ID`, `WHOOP_ACCESS_TOKEN`, …) are **unchanged** and still feed `integrations.py`.

## Call a few endpoints

```python
from whoop_private import WhoopPrivateClient

client = WhoopPrivateClient()
client.ensure_auth()  # sign in or refresh

stress = client.stress("2026-05-24")          # intraday timeline
strain = client.strain("2026-05-24")          # day strain deep dive
workout = client.workout_detail("<activity-uuid>")  # HR curve / zones / MSK

print(stress.current_level, strain.score, workout.strain)
```

Other typed helpers: `live_stress`, `recovery_deep_dive`, `sleep_deep_dive`, `trend` / `trends`, `sleep_need`, `live_hr`, `live_user_state`, `strength_prs`, `strength_progression`, `journal_behaviors`, `behavior_impact`.

Everything else in the 311-row catalog is reachable via:

```python
from whoop_private import find_endpoints

specs = find_endpoints(path_contains="smart-alarm")
client.call(specs[0], path_params={"uuid": "…"})

# or fully raw
client.request("GET", "/hr-zones-service/v1/bff/zones")
```

Destructive calls (activity delete, journal autopop, …) require `confirm=True`. Without it you get a preview payload only:

```python
client.delete_workout(activity_id, confirm=False)  # preview
client.delete_workout(activity_id, confirm=True)   # actually DELETE
```

## Tests

```bash
cd backend
python3 -m unittest whoop_private.tests.test_client -v
# or via the quest stub check (also runs integrations/history/mercury checks):
python3 app.py --check
```

Tests never hit the live WHOOP API.

## Already in this repo (skipped here)

| Surface | Where |
|---|---|
| OAuth2 authorize / token / refresh | `integrations.py` |
| `GET /developer/v2/recovery` | `whoop_snapshot`, `history.fetch_whoop` |
| `GET /developer/v2/cycle` | same |
| `GET /developer/v2/activity/sleep` | same |
| `GET /developer/v2/activity/workout` | `whoop_snapshot` |
| Webhook signature check | `integrations.verify_whoop_signature` |

Body measurement / profile are in the OAuth scopes but unused; still treated as public-API territory and not reimplemented here.
