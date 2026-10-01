# Phase 7 — enable penalties on a device

This VM cannot compile the SwiftUI app or the Screen Time extensions. The sources and the Xcode project entries are in the tree. Signing, Family Controls, and a physical iPhone still have to be done on a Mac.

The four swipe screens are unchanged. Status gained two controls: the existing Full Recovery row now asks before spending a token, and **DISTRACTOR SHIELDS** opens a picker sheet.

## What the phone does

Quest days roll at America/Los_Angeles midnight.

1. If a required quest (anything that is not `optional`) is still incomplete, the next morning raises `penaltyTier` by one, capped at 3, and builds the fallback **Penalty Quest** bundle.
2. A Full Recovery day does not raise the tier. Status → **FULL RECOVERY** → **Spend token**. A quiet morning (no completed quest, no running timer) assigns today and rebuilds. A day already underway queues tomorrow and keeps today's progress. A second spend the same day is refused and does not take another token.
3. Shields apply only while the visible mode is `penalty` (`penaltyTier > 0` and not a Full Recovery day). They cover the apps, categories, and sites chosen in the picker. They are not a phone lock.
4. Completing every required penalty quest sets the tier to 0, calls `clearAllSettings()` on the named store `penalty`, stops monitoring, and ends the Live Activity. Undo of a penalty quest the same day restores the tier and the shields.
5. Penalty XP is `0.9×` once, from the quest's own XP, at the moment it is granted (30 becomes 27). Clearing the penalty does not tax again.
6. The Live Activity is started and updated only from the foreground app. Its stale date is 8 hours after `penaltyStartedAt`. After that window the app does not request a new one. Shields and the Device Activity monitor stay up until the penalty is cleared or the day is Full Recovery. A rest day does not reset `penaltyStartedAt`, so a leftover tier does not get a fresh 8 hours.
7. The shield button says "Open The System" and returns `.defer`. It does not clear the shield and it does not deep-link. Open the app from the home screen and finish the penalty quests there.
8. `screen_time_limit` stays a local checkbox. DeviceActivity does not give this app minute totals. The picker selection is not minute data, and it is not sent in `MorningContext` or to the backend.

The monitor's `intervalDidEnd` re-asserts shields when `penaltyActive` is still true. Ending the 00:00–23:59 schedule does not lift them. That schedule follows the device clock. The quest-day check follows America/Los_Angeles, and the app applies or clears shields the next time it is in the foreground.

## Checklist

1. Open `system.xcodeproj` on a Mac with Xcode. Select the **MyApp** scheme and an iPhone destination. Family Controls does not run in the simulator.
2. Keep the placeholder bundle ids unless you register different ones. With `PROJECT_UNIQUE_VALUE` `HDDJMVMX` they are:
   - `devplaceholder.HDDJMVMX.MyApp`
   - `devplaceholder.HDDJMVMX.MyApp.PenaltyMonitor`
   - `devplaceholder.HDDJMVMX.MyApp.PenaltyShieldConfig`
   - `devplaceholder.HDDJMVMX.MyApp.PenaltyShieldAction`
   - `devplaceholder.HDDJMVMX.MyApp.PenaltyActivity`
3. On each of those App IDs, add the App Group `group.devplaceholder.HDDJMVMX.thesystem`. The same string is in `PenaltyGroup.suiteName` and in each extension file (`PenaltyMonitorGroup` is the copy inside the monitor). If the portal id changes, change every copy.
4. Turn on the Family Controls capability for MyApp, PenaltyMonitor, PenaltyShieldConfig, and PenaltyShieldAction. The iOS entitlements file is `MyApp-iOS.entitlements` (HealthKit plus Family Controls plus the App Group). `MyApp.entitlements` stays HealthKit-only so visionOS is unchanged. The Live Activity extension only has the App Group; it does not call Family Controls.
5. Request **Family Controls (Distribution)** from Apple for each App ID that carries that entitlement before TestFlight or the App Store. A development build can use the boolean entitlement after the capability is on the App ID. Distribution approval is still open.
6. Confirm the four extension targets embed in MyApp. The project uses an Embed Foundation Extensions phase with `platformFilter = ios`, so a Mac build skips the appex files. Extension targets are iOS-only (`iphoneos` and `iphonesimulator`). If a Mac scheme still tries to compile them, uncheck those targets for the macOS destination.
7. `NSSupportsLiveActivities` is already set on MyApp for `iphoneos` and `iphonesimulator` only. Extension targets set `SWIFT_DEFAULT_ACTOR_ISOLATION` to `nonisolated` so `DeviceActivityMonitor` overrides are not MainActor. The app target stays MainActor.
8. Run on the iPhone. Status → **DISTRACTOR SHIELDS**. The sheet calls `AuthorizationCenter.shared.requestAuthorization(for: .individual)`. Pick the distractor apps, categories, and sites, then Save. The selection is property-list encoded in the App Group under `familyActivitySelection`. The quest snapshot stores only `hasDistractorSelection`.
9. Leave a required quest incomplete across an America/Los_Angeles midnight, then open the app. System should show **Penalty Quest**, tier 1. Selected distractors should shield. Lock Screen and Dynamic Island should show `PENALTY ACTIVE` and the first incomplete quest title, until the 8-hour limit.
10. Finish every required penalty quest. Shields lift, the Live Activity ends, and the tier returns to 0.

## If Xcode rejects the project

The extension targets were added to `project.pbxproj` without Xcode. Sources live outside `MyApp/` so the app's synchronized folder does not compile them. Each extension folder is its own synchronized root. `Info.plist` and the `.entitlements` file are membership exceptions so they are not copied as resources.

If the project will not open, add the four targets by hand and point them at the existing folders:

| Target | Extension point | Principal class |
| --- | --- | --- |
| PenaltyMonitor | `com.apple.deviceactivity.monitor` | `$(PRODUCT_MODULE_NAME).PenaltyDeviceActivityMonitor` |
| PenaltyShieldConfig | `com.apple.ManagedSettingsUI.shield-configuration-service` | `$(PRODUCT_MODULE_NAME).PenaltyShieldConfiguration` |
| PenaltyShieldAction | `com.apple.ManagedSettingsUI.shield-action-service` | `$(PRODUCT_MODULE_NAME).PenaltyShieldAction` |
| PenaltyActivity | `com.apple.widgetkit-extension` | none (`@main` `PenaltyActivityBundle`) |

For each target: iOS only, Skip Install, Application Extension API Only, Generate Info.plist File off, Info.plist and entitlements paths as in the folder, and embed the product in MyApp for iOS. `PenaltyAttributes` in `MyApp/Engine/PenaltyActivityAttributes.swift` and `PenaltyActivity/PenaltyActivityAttributes.swift` must stay identical.

If a shield or monitor override fails to compile, match the method to the current SDK. The names used here are `configuration(shielding:)`, `configuration(shielding:in:)`, `handle(action:for:completionHandler:)`, `ShieldActionResponse.defer`, `ManagedSettingsStore(named:).clearAllSettings()`, and `Activity.request(attributes:content:pushType:)`.

## Still later

Silent push when a verifier clears a quest, DeviceActivityReport charts, and History day-clear cards are not in this phase. Family Controls distribution approval and a physical-device pass are the remaining penalty work.
