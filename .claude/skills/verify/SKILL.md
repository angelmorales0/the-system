---
name: verify
description: Build the iOS app and run it in the Simulator to prove a change works. Run after EVERY code change to Swift files, the Xcode project, Info.plist, entitlements, or resources, before you tell the user the work is done. A change is not done until this passes.
---

# Verify the app

A code change is **not implemented** until this skill passes. Do not tell the
user a change is done, and do not ask them to build in Xcode, until it passes.

## Run

```bash
.claude/skills/verify/verify.sh
```

Run it with a 600000 ms timeout. It takes a few minutes.

The script does 5 steps and stops at the first failure:

| Step | What it checks | Exit code on failure |
|---|---|---|
| 1 | `xcodebuild` for the iOS Simulator (scheme `MyApp`, Debug, `CLOUDKIT_SYNC=NO`) | 1 |
| 2 | `xcodebuild` for a real iPhone, without signing | 2 |
| 3 | `xcodebuild` for the Mac tracker (scheme `FocusTracker`, macOS), without signing | 5 |
| 4 | Boot a Simulator and install the app (fresh data) | 3 |
| 5 | Launch the app twice (first launch, then relaunch). Each launch must stay alive for `RUN_SECONDS` (15) with no crash, no `precondition`/`fatalError`, and no crash report | 4 |

Unsigned builds have no iCloud entitlement, and CloudKit stops an app without it.
So the Simulator build that runs turns CloudKit off. Steps 2 and 3 keep it on, so
the CloudKit code still compiles.

Logs and screenshots go to `$TMPDIR/system-verify/`.

## After it runs

1. **Exit 0:** Read both screenshots (`screen-first.png`, `screen-relaunch.png`)
   with the Read tool. Make sure the screen shows the feature that you changed and
   no error or blank screen. If the change is on a screen that the app does not
   show at launch, say that you could not see it in the screenshot.
2. **Exit 1, 2, or 5:** Fix the compile errors that the script printed. Read the full
   log only if the printed errors are not enough. Then run the script again.
3. **Exit 3:** This is an environment problem (no Simulator, boot failure). Try
   `SIM_UDID=<id>` with another device from `xcrun simctl list devices available`.
   Tell the user if it still fails.
4. **Exit 4:** Read the console log and the crash report that the script printed.
   In Debug builds, `GameStore.init` runs self-checks (`VerificationFixtures`,
   `TargetRules`, `QuestGenerationRules`, `IntegrationRules`, `PenaltyRules`) and
   calls `precondition` when one fails. The message names the failed check.
   Decide if the bug is in the app or in the check, fix the real cause, and run
   the script again.
5. Repeat until it passes. Do not weaken or delete a self-check only to make it
   pass. Change a check only when the check itself is wrong, and say why.

## Lessons from past failures

- Xcode shows only the first few errors. The script shows all of them.
- Missing imports are common: `UserDefaults`/`PropertyListDecoder` need
  `Foundation`, `@Published`/`ObservableObject` need `Combine`
  (the project enables `MemberImportVisibility`).
- A local `let` with the same name as a static func hides the func
  ("Cannot call value of non-function type").
- App extensions need `GENERATE_INFOPLIST_FILE = YES`, or their `Info.plist`
  has no `CFBundleIdentifier` and embedding fails.
- String checks for leaked names can match by accident (`Angel` in
  `America/Los_Angeles`).

## Limits

- No code signing. Signing, provisioning, App Group, and Family Controls
  entitlement problems show only when the user runs on a real iPhone from Xcode.
- Screen Time, HealthKit, and other device-only features do not fully work in
  the Simulator.
- The screenshots show only the first screen. The script does not tap the UI.

## Report to the user

State the result plainly: which steps passed, the warning count, and what the
screenshot shows. If something failed and you could not fix it, show the error
output.
