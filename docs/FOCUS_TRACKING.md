# Screen time: iPhone and Macs

| Source | What it counts | Where it goes |
|---|---|---|
| iPhone (FOC tracking) | Screen time and social media per quest day, from Screen Time thresholds | FOC stat |
| iPhone (Screen Time quest) | Phone minutes today | The quest's Phone line |
| Every Mac (FocusTracker) | Active minutes: screen unlocked and input in the last 5 minutes. No apps, windows, or websites. | The quest's **Work** line, through the screen time Worker |

All Mac time counts as work. FOC counts the iPhone only, because work hours would break its "under 2 h a day" rule.

```
FocusTracker (each Mac) ──POST minutes every 15 min──▶ Cloudflare Worker ◀──GET today── iPhone app
```

## 1. Deploy the Worker (free, about 10 minutes)

1. Make a free account at dash.cloudflare.com.
2. **Storage & Databases → KV → Create** a namespace named `screentime`.
3. **Compute (Workers) → Create → Start with Hello World**. Name it `screentime`, then **Deploy**.
4. **Edit code**: replace everything with [`screentime-worker/worker.js`](../screentime-worker/worker.js), then **Deploy**.
5. On the Worker, open **Settings → Bindings → Add → KV namespace**. Variable name `SCREEN`, namespace `screentime`.
6. **Settings → Variables and Secrets → Add**. Type **Secret**, name `TOKEN`. For the value, make a long random string, for example from Terminal:
   ```bash
   openssl rand -hex 24
   ```
   Keep it in your password manager. You type it into each Mac and the iPhone.
7. Note the Worker address, for example `https://screentime.<you>.workers.dev`.
8. Test it from any Mac, including the work Mac. It must print `{"ok":true}`:
   ```bash
   curl https://screentime.<you>.workers.dev/health
   ```

## 2. iPhone

Status → Screen Time → **Set up Mac tracker**. Enter the Worker address and token, then **Save and test**.

## 3. Personal Mac (has Xcode)

1. Xcode → Settings → Accounts: sign in. Select your team on the **FocusTracker** target.
2. Choose the **FocusTracker** scheme and **My Mac**, then Run (⌘R).
3. Product → Show Build Folder in Finder → `Products/Debug`. Copy **FocusTracker.app** to Applications, quit the Xcode copy, and open the one in Applications.
4. Menu-bar eye icon → **Set Up…** → address and token → **Save and Test**.

## 4. Work Mac (no Xcode)

On the personal Mac, once:

```bash
xcrun notarytool store-credentials the-system-notary --apple-id <you@example.com> --team-id <TEAMID>
```

Then build the installer:

```bash
TEAM_ID=<TEAMID> scripts/package-focustracker.sh
```

Copy `build/FocusTracker.dmg` to the work Mac, open it, and drag FocusTracker to Applications. Open it, then **Set Up…** with the same address and token.

## Checking it works

- Mac menu: "Today: 1 h 12 min" goes up while you use the Mac, and "Sent 10:45 AM" updates every 15 minutes.
- iPhone: the Screen Time quest's Work line shows the minutes of all Macs together.
- Worker: Cloudflare dashboard → KV → `screentime` shows one `day:YYYY-MM-DD` key per day.

## Limits

- FocusTracker counts only while it runs. If you quit it, that time is not counted.
- A video with no keyboard or mouse input stops counting after 5 minutes.
- If the work network blocks the Worker, minutes wait on the Mac and send when it can reach it.
- Anyone with the token can read and write your Mac minutes. Keep it private; change the `TOKEN` secret to revoke it.
