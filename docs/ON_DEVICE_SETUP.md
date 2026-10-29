# On-device setup

The app reads every service from the iPhone. No server is needed.

## Strava

1. Open https://www.strava.com/settings/api and create an app (one athlete is enough).
2. Set **Authorization Callback Domain** to `localhost`.
3. In the app, open **Status → Connections → Strava**. Type the **Client ID** and **Client Secret**. Tap **Save and test**.
4. Tap **Sign in to Strava** and approve. The app uses the redirect `thesystem://localhost/strava`.

## WHOOP

WHOOP accepts a custom-scheme redirect URL (its docs show `whoop://example/redirect` as a valid form), so the app signs in directly.

1. Open https://developer-dashboard.whoop.com and create an app.
2. Add the **Redirect URL** `thesystem://localhost/whoop`. It must match exactly.
3. Choose the scopes `offline`, `read:recovery`, `read:sleep`, `read:cycles`, `read:workout`, and `read:body_measurement`.
4. In the app, open **Status → Connections → WHOOP**. Type the **Client ID** and **Client Secret**. Tap **Save and test**.
5. Tap **Sign in to WHOOP** and approve.

WHOOP gives a new refresh token on each refresh. The app saves it in the Keychain each time and runs one refresh at a time.
