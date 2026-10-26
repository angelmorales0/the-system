# Focus tracking: iPhone and Mac screen time

The FOC stat scores daily screen time and social media from two sources:

| Source | How | Where it goes |
|---|---|---|
| iPhone | The PenaltyMonitor extension gets a `focusDay` schedule (5:00 to 4:59) with an event at each FOC threshold. It saves the highest threshold reached per quest day. | App Group key `focusDays` |
| Mac | The FocusTracker menu-bar app counts active time every 15 seconds (screen unlocked, input in the last 5 minutes). Social apps and social sites in Safari or Chrome count as social. | Private iCloud database, container `iCloud.com.angelmorales.thesystem` |

The app adds the Mac minutes to the iPhone minutes for each day. A day counts only when the iPhone logged it.

## One-time setup

1. In Xcode, open Settings → Accounts and sign in with your Apple Developer account.
2. Select the project. For the **MyApp**, **PenaltyMonitor**, **PenaltyShieldConfig**, **PenaltyShieldAction**, **PenaltyActivity**, and **FocusTracker** targets, open Signing & Capabilities and select your team.
3. In the **MyApp** and **FocusTracker** targets, make sure the iCloud capability shows the container `iCloud.com.angelmorales.thesystem` with a check mark. If Xcode shows it in red, click the refresh button under the container list.
4. Run **MyApp** on your iPhone. Open Status → FOC → Set up tracking.
   - **All apps:** select every category.
   - **Social apps:** select your social apps and sites.
5. Run **FocusTracker** on your Mac (scheme FocusTracker, destination My Mac). An eye icon shows in the menu bar.
   - The first time it runs, it adds itself to Login Items. macOS shows "Background item added."
   - The first time Safari or Chrome is in front, macOS asks to allow FocusTracker to control it. Click Allow.

## What to expect

- The iPhone starts counting at the next 5:00.
- The Mac sends each finished day to iCloud after 5:00, or when it is next online. The iPhone reads the last 30 days each time it refreshes its stats.
- The FOC target rows show the Mac share, for example "incl. Mac avg 34 min on 12 days".

## Limits

- iOS reports thresholds (30, 60, 90, 120, ... minutes), not exact minutes. A day at 119 minutes reads as 90.
- FocusTracker counts only while it runs. If you quit it, that time is not counted.
- A video with no keyboard or mouse input stops counting after 5 minutes.
- Only Safari and Chrome sites count as social. Other browsers count as screen time only.
- The verify script builds with `CLOUDKIT_SYNC=NO` for the Simulator run, because unsigned builds have no iCloud entitlement. Real iCloud sync needs a signed build on your devices.
- Xcode builds use the CloudKit development environment. A TestFlight or App Store build needs the schema deployed to production in the CloudKit Console first.
