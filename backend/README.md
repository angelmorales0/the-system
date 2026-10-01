# Quest generation stub

Local stand-in for `POST /v1/quests/generate`. It checks the morning-context shape, then returns a quest bundle from templates. If `XAI_API_KEY` is set in the environment, it asks xAI Grok (`grok-4.6` unless `XAI_MODEL` overrides it) and keeps the reply only when that reply passes the same safety checks. Otherwise it serves the template.

The app does not read a secrets file. Nothing in this directory should contain a live key.

## Run

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python app.py --check
python app.py
```

The server listens on `http://127.0.0.1:8787`.

To use Grok, export the key in the shell (or source a gitignored `.env` you created from `.env.example`) and start the process in that same shell:

```bash
export XAI_API_KEY
export XAI_MODEL=grok-4.6
python app.py
```

`GET /health` reports whether the process will call Grok or stay on templates. It does not print the key.

## iOS

With no base URL, the app uses the on-device mock (the fallback catalog for the rules-locked mode). To send morning context to this stub:

Launch the app with `QUEST_GENERATE_BASE_URL=http://127.0.0.1:8787` (Xcode scheme environment, or `simctl launch --env`). The simulator reaches this process at `127.0.0.1`.

Or set UserDefaults key `com.angelmorales.thesystem.questGenerateBaseURL` to `http://127.0.0.1:8787` and relaunch. Only `http` and `https` URLs are used. A timeout past 8 seconds, or a bundle that fails the on-device check, keeps the fallback catalog. The phone never sends an API key.

## WHOOP and Strava

Secrets stay in the environment. Copy `backend/.env.example` to a gitignored `.env`, fill in the values from the developer portals, and export them in the shell before `python app.py`. The server writes refresh tokens to `backend/.secrets/` (also gitignored) and never returns them to the app.

WHOOP scopes: `offline read:recovery read:sleep read:cycles read:workout read:body_measurement`. Redirect: `http://127.0.0.1:8787/v1/oauth/whoop/callback`. Dashboard: https://developer-dashboard.whoop.com/

Strava scope: `activity:read_all`. Redirect: `http://127.0.0.1:8787/v1/oauth/strava/callback`. Create the app at https://www.strava.com/settings/api (Single Player Mode is enough for one athlete).

1. Export `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, and the redirect URI. Do the same for `STRAVA_CLIENT_ID` and `STRAVA_CLIENT_SECRET`.
2. Open `GET /v1/oauth/whoop/start` and visit `authorizeUrl`. After you approve, the callback stores the tokens. Repeat for `/v1/oauth/strava/start`.
3. `GET /v1/integrations/whoop/snapshot?day=YYYY-MM-DD` and `GET /v1/integrations/strava/snapshot?day=YYYY-MM-DD` return summaries only. Without tokens they return `configured: false` and a TODO reason. The iOS verifiers stay incomplete and do not check the quest off.
4. Point the app at this server with `QUEST_GENERATE_BASE_URL`. The phone calls those snapshot URLs. It does not see client secrets or refresh tokens.
5. WHOOP webhooks: `POST /v1/webhooks/whoop` checks `X-WHOOP-Signature` (base64 HMAC-SHA256 of the timestamp plus the raw body, using `WHOOP_WEBHOOK_SECRET` or the client secret). Strava's subscription handshake is `GET /v1/webhooks/strava` with `hub.verify_token` equal to `STRAVA_WEBHOOK_VERIFY_TOKEN`. Strava does not sign each event; the POST is accepted only after that verify token is set.

`POST /v1/oauth/whoop/refresh` and `POST /v1/oauth/strava/refresh` exchange the stored refresh token. WHOOP rotates that token; the new one replaces the file. A failed refresh does not invent workouts.

HealthKit is on-device only. In Apple Health, allow workouts, protein, dietary energy, weight, and sleep. MacroFactor has no API: turn on More → Integrations → Apple Health so its protein and weight samples are preferred when they are present. The HealthKit entitlement is in `MyApp.entitlements` for iOS; turn on HealthKit for the App ID in the developer portal before running on a device.

## Mercury

The Read Only token stays in the environment. The app never sees it. Copy `backend/.env.example` and export the variables in the same shell that runs `python app.py`.

1. In Mercury, open the organization menu and choose **All Settings → Tokens**.
2. Create an API token and choose **Read Only**. Read and Write is not required and needs an IP whitelist. If Tokens is missing, the signed-in user cannot create tokens; an admin has to grant that, or write personal@mercury.com / api@mercury.com.
3. Copy the token once. Mercury will not show it again. Export it as `MERCURY_API_TOKEN`. Do not commit it. A gitignored `.env` is fine if you source it yourself; this process does not load dotenv.
4. Production base URL is `https://api.mercury.com/api/v1` (`MERCURY_API_BASE_URL`). For a sandbox token, set that variable to the sandbox host Mercury documents for the token. Webhooks are not available in sandbox.
5. Start the server and sync. Sync lists accounts and transactions (cursor pages of up to 1000) and stores summaries in `backend/.secrets/mercury_ledger.json`. Account numbers and routing numbers are not stored.

```bash
export MERCURY_API_TOKEN
export MERCURY_API_BASE_URL=https://api.mercury.com/api/v1
python app.py
```

```bash
curl -X POST http://127.0.0.1:8787/v1/integrations/mercury/sync
curl "http://127.0.0.1:8787/v1/integrations/mercury/snapshot?day=YYYY-MM-DD"
```

`GET /v1/integrations/mercury/accounts` and `GET /v1/integrations/mercury/transactions?limit=100&start_after=` read that cache. Without a token the snapshot is `configured: false` with a TODO reason, and the spend quest stays incomplete.

Point the app at this server with `QUEST_GENERATE_BASE_URL`. The phone calls the snapshot URL only.

Spend is split with an on-server category map: Grocery, Utilities, Insurance, Medical, Taxes, and rent-like counterparties are necessary. Restaurants, Entertainment, Retail, and the other merchant types are discretionary. Uncategorized debits count as discretionary. Copy `mercury_categories.example.json` to `mercury_categories.json` (gitignored) or set `MERCURY_CATEGORY_MAP` to a JSON object of category name → `necessary` or `discretionary`.

YTD income is credits in the calendar year, in America/Los_Angeles, excluding `internalTransfer`, `treasuryTransfer`, and `interestPayment`. The goal is $500,000 pre-tax. Set `MERCURY_INCOME_COUNTERPARTY_REGEX` to count only matching counterparties; leave it empty to count every other credit.

Pace states are undecided defaults, not a locked budget:

- Daily soft cap $40, weekly soft cap $280, balance floor $500.
- Burn under 0.75 of the elapsed cap is `NORMAL`, under 1.00 is `CAUTION`, under 1.25 is `WARNING`, otherwise `CRITICAL`.
- Available balance under the floor is at least `WARNING`.

`mercury_spend_under` completes only after a sync has landed, the local day is settled, and discretionary spend is still at or under the quest cap (default $40). Settlement is `MERCURY_SETTLE_HOUR` (default 21) in America/Los_Angeles, or any time the requested day is already in the past. Spend over the cap fails and does not clear the quest. A missing token, or a webhook that arrived before the first sync, does not clear it either.

The FIN radar adds at most 20 projection points on top of quest XP (pace 0–8, progress toward the $500K goal 0–12). It is not the account balance.

Webhooks: create an endpoint in Mercury aimed at `POST /v1/webhooks/mercury` for `transaction.created`, `transaction.updated`, `checkingAccount.balance.updated`, `savingsAccount.balance.updated`, and `creditAccount.balance.updated`. Put that endpoint's secret in `MERCURY_WEBHOOK_SECRET`. The server checks `Mercury-Signature` as HMAC-SHA256 of `timestamp.raw_body` and rejects a skew over 5 minutes. A transaction event refetches `GET /transaction/{resourceId}` and updates the cache. Unused tokens are deleted after 45 days; a sync or any other GET inside 30 days keeps the token.
