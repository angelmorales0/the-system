# On-device setup

The app reads every service from the iPhone. No server is needed. The Mac screen time Worker (`screentime-worker/`) is separate and stays as it is.

Open **Status → Connections**. Each service has a row with its state (**Connected**, **Not set**, or **Error**) and a **Test** button. Tap a row to type its values.

## Where the keys go

- Each key, token, and client secret goes into this iPhone's Keychain. The Keychain items are available after the first unlock, stay on this device, and are not synced.
- Keys never go into UserDefaults, the App Group, logs, or the quest context that goes to Claude.
- After you save a value, the app does not show it again. To change it, type the new value and tap **Save and test**. **Remove** deletes every saved value for that service.
- Do not put a real key in this repository. The repository is public.

## Summary

| Service | What you type in the app | Where you get it | Portal setting to change |
|---|---|---|---|
| Hevy | API key | hevy.com → Settings → Developer (Hevy Pro) | None |
| Strava | Client ID, Client Secret, then sign in | strava.com/settings/api | Authorization Callback Domain: `localhost` |
| WHOOP | Client ID, Client Secret, then sign in | developer-dashboard.whoop.com | Redirect URL: `thesystem://localhost/whoop`, and the scopes below |
| Codeforces | Your handle | Your Codeforces profile | None (public API) |
| Mercury | Read Only API token | Mercury → Settings → Tokens | None (Read Only needs no IP allowlist) |
| Claude | Anthropic API key | console.anthropic.com → API Keys | None |

## Hevy

1. You need Hevy Pro. Open https://hevy.com/settings and go to **Developer**.
2. Copy the API key.
3. In the app, open **Status → Connections → Hevy**. Paste the key. Tap **Save and test**.

The phone reads workouts, exercises, and sets (reps, kg, RPE, hold time). It does not read notes or descriptions. Lifts check off from Hevy.

## Strava

1. Open https://www.strava.com/settings/api and create an app. One athlete (you) is enough.
2. Set **Authorization Callback Domain** to `localhost`.
3. In the app, open **Status → Connections → Strava**. Type the **Client ID** and **Client Secret**. Tap **Save and test**. (The test fails until you sign in.)
4. Tap **Sign in to Strava** and approve. The app uses the redirect `thesystem://localhost/strava` and the scope `activity:read_all`.
5. Tap **Test**. It should say "Connected to Strava."

Strava matches the redirect's host (`localhost`) against the callback domain. The code exchange and each token refresh run on the phone with your client secret.

## WHOOP

WHOOP accepts a custom-scheme redirect URL (its OAuth docs show `whoop://example/redirect` as a valid form), so the app signs in directly. No web server is needed.

1. Open https://developer-dashboard.whoop.com and create an app.
2. Add the **Redirect URL** `thesystem://localhost/whoop`. It must match exactly.
3. Choose the scopes `offline`, `read:recovery`, `read:sleep`, `read:cycles`, `read:workout`, and `read:body_measurement`.
4. In the app, open **Status → Connections → WHOOP**. Type the **Client ID** and **Client Secret**. Tap **Save and test**.
5. Tap **Sign in to WHOOP** and approve.
6. Tap **Test**. It should say "Connected to WHOOP."

WHOOP gives a new refresh token on each refresh. The app saves it to the Keychain each time and runs only one refresh at a time, because a second refresh with the old token fails. If a refresh fails, the row shows **Error**: sign in again.

## Codeforces

1. In the app, open **Status → Connections → Codeforces**.
2. Type your handle. Tap **Save and test**.

The handle is public, so it is kept in UserDefaults, not the Keychain. INT reads the current rating from `user.info` and the contest count from `user.rating`.

## Mercury

1. In Mercury, open the organization menu and choose **Settings → Tokens**.
2. Create an API token and choose **Read Only**. Copy it once; Mercury does not show it again.
3. In the app, open **Status → Connections → Mercury**. Paste the token. Tap **Save and test**. The test lists your accounts and syncs the transactions.
4. Under **FIN settings**, set what the backend used to read from its environment:
   - **Monthly budget** (was `MONTHLY_BUDGET_USD`). Empty means budget adherence is not configured.
   - **Tax reserve** 0–60% (was `MONTHLY_TAX_RESERVE_RATE`). Mercury sees deposits, not taxes.
   - **Day settles at** (was `MERCURY_SETTLE_HOUR`, default 21:00 Los Angeles).
   - **Income counterparty regex** (was `MERCURY_INCOME_COUNTERPARTY_REGEX`). Empty counts every other credit.
   - **Category map** (was `mercury_categories.json`): one `Category=tag` per line. Tags: `necessary`, `discretionary`, `transfer`, `income`, `ignore`.
   - **API base URL**: empty for production. Only `https` is used.

There are no webhooks. While the app is open, it polls Mercury at most every 15 minutes. It lists transactions from January 1 (or from the first day of last month in January) and keeps a slim summary of each one (id, amount, category, kind, status, dates, counterparty name, account id) in the app's Application Support folder. Account and routing numbers are not kept. The token is not in that file. Unused Mercury tokens expire after 45 days without a call.

## Claude

1. Open https://console.anthropic.com, go to **API Keys**, and create a key.
2. In the app, open **Status → Connections → Claude**. Paste the key. Tap **Save and test**. The test reads the model's entry from the Models API; it uses no tokens.
3. **Model** is `claude-opus-5-5` when the field is empty. Type another model id to change it.

How the morning plan runs:

- When the app opens on a new quest day, it reads today's data, then 30 days of Hevy, Strava, and WHOOP, and sends the morning context to the Messages API. The request uses adaptive thinking at `high` effort, a cached prefix (system prompt plus context), and server-side refusal fallbacks (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`).
- A plan that breaks a rule goes back to Claude with the reason, up to 3 calls in 100 seconds. If every plan is rejected, the app uses the template plan.
- The catalog quests stay on screen until a valid plan arrives. Nothing you finished is replaced.
- Planning can take up to about 2 minutes. If the app leaves the screen, iOS gives it about 30 seconds more. If no reply comes back, the app tries again on the next open, up to 3 times a day.
- Without a Claude key, the app uses its offline plan.
- If you save a Claude key after this morning's offline plan, and nothing is done yet, the app plans today again.

## What was not tested with real accounts

The self-checks run on fixture data at each Debug launch. Real calls to Hevy, Strava, WHOOP, Codeforces, Mercury, and the Anthropic API were not made while this was built, because no keys were used. Test each service with its **Test** button after you set it up.
