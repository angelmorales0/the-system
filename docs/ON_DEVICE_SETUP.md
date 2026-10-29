# On-device setup

The app reads every service from the iPhone. No server is needed.

## Strava

1. Open https://www.strava.com/settings/api and create an app (one athlete is enough).
2. Set **Authorization Callback Domain** to `localhost`.
3. In the app, open **Status → Connections → Strava**. Type the **Client ID** and **Client Secret**. Tap **Save and test**.
4. Tap **Sign in to Strava** and approve. The app uses the redirect `thesystem://localhost/strava`.
