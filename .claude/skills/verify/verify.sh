#!/bin/bash
# Verifies the iOS app: Simulator build, device build, the Mac FocusTracker build, then launches
# the iOS app in the Simulator twice (fresh install + relaunch) and checks for crashes.
# Exit codes: 0 pass, 1 Simulator build failed, 2 device build failed,
#             3 Simulator setup failed, 4 app crashed or did not stay running,
#             5 FocusTracker (macOS) build failed.

#
# Env overrides:
#   SIM_UDID     Simulator to use (default: first available iPhone)
#   RUN_SECONDS  Seconds each launch must stay alive (default: 15)
#   KEEP_DATA=1  Do not uninstall before the first launch

set -u
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PROJECT="$ROOT/system.xcodeproj"
SCHEME="MyApp"
OUT="${TMPDIR:-/tmp}/system-verify"
DD="$OUT/DerivedData"
RUN_SECONDS="${RUN_SECONDS:-15}"
mkdir -p "$OUT"
cd "$ROOT" || exit 3

fail() { echo "VERIFY FAILED ($2): $1"; exit "$2"; }

show_build_errors() {
    grep -E '^/.*: error:|^error:|^\s+error:' "$1" | sort -u | head -40
    grep -A6 'error: Embedded binary' "$1" | head -20
}

# 1. Simulator build
echo "== [1/5] Build for iOS Simulator"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/build-sim.log" 2>&1
if ! grep -q 'BUILD SUCCEEDED' "$OUT/build-sim.log"; then
    show_build_errors "$OUT/build-sim.log"
    fail "Simulator build. Full log: $OUT/build-sim.log" 1
fi
WARNINGS=$(grep -E '^/.*: warning:' "$OUT/build-sim.log" | sort -u | wc -l | tr -d ' ')
echo "   ok ($WARNINGS warnings in files compiled this run)"

# 2. Device build (no signing: signing needs the user's Apple account in Xcode)
echo "== [2/5] Build for iOS device (unsigned)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/build-device.log" 2>&1
if ! grep -q 'BUILD SUCCEEDED' "$OUT/build-device.log"; then
    show_build_errors "$OUT/build-device.log"
    fail "Device build. Full log: $OUT/build-device.log" 2
fi
echo "   ok"

# 3. Mac tracker build
echo "== [3/5] Build FocusTracker for macOS (unsigned)"
xcodebuild -project "$PROJECT" -scheme FocusTracker -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/build-mac.log" 2>&1
if ! grep -q 'BUILD SUCCEEDED' "$OUT/build-mac.log"; then
    show_build_errors "$OUT/build-mac.log"
    fail "FocusTracker build. Full log: $OUT/build-mac.log" 5
fi
echo "   ok"

# 4. Simulator setup
echo "== [4/5] Prepare Simulator"
UDID="${SIM_UDID:-$(xcrun simctl list devices available | grep -E '^\s+iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')}"
[ -n "$UDID" ] || fail "No available iPhone Simulator" 3
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || fail "Simulator $UDID did not boot" 3
APP="$DD/Build/Products/Debug-iphonesimulator/$SCHEME.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist") || fail "No bundle ID in $APP" 3
[ "${KEEP_DATA:-0}" = 1 ] || xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null
xcrun simctl install "$UDID" "$APP" || fail "Install failed" 3
echo "   $UDID  $BUNDLE_ID"

# 5. Launch twice: first launch (fresh state) and relaunch (saved state)
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
MARKER="$OUT/.launch-marker"
run_once() {
    local label="$1" log="$OUT/launch-$1.log"
    touch "$MARKER"
    xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" > "$log" 2>&1 &
    local launcher=$!
    local alive=0 i pid
    for i in $(seq 1 "$RUN_SECONDS"); do
        sleep 1
        pid=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
            | grep "UIKitApplication:$BUNDLE_ID" | awk '{print $1}' | head -1)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then alive=1; else alive=0; fi
        # Stop early once the app has died after starting.
        [ "$i" -gt 3 ] && [ "$alive" = 0 ] && break
    done
    xcrun simctl io "$UDID" screenshot "$OUT/screen-$label.png" > /dev/null 2>&1
    kill "$launcher" 2>/dev/null; wait "$launcher" 2>/dev/null

    local problems
    problems=$(grep -E 'Fatal error|Precondition failed|Assertion failed|precondition failure|EXC_BAD|SIGABRT|Thread [0-9]+ Crashed|Unexpectedly found nil' "$log" | head -10)
    local crash
    crash=$(find "$CRASH_DIR" -newer "$MARKER" -name "${SCHEME}*" 2>/dev/null | head -1)
    if [ "$alive" = 0 ] || [ -n "$problems" ] || [ -n "$crash" ]; then
        echo "   $label launch FAILED (alive=$alive)"
        [ -n "$problems" ] && echo "$problems"
        [ -n "$crash" ] && { echo "   crash report: $crash"; grep -m5 -E '"(exception|termination)"|Precondition|Fatal' "$crash"; }
        echo "   console log: $log"
        echo "   screenshot: $OUT/screen-$label.png"
        fail "App did not run cleanly on $label launch" 4
    fi
    echo "   $label launch ok (${RUN_SECONDS}s) screenshot: $OUT/screen-$label.png"
}
echo "== [5/5] Run in Simulator"
run_once first
run_once relaunch

echo "VERIFY PASSED"
echo "Screenshots: $OUT/screen-first.png $OUT/screen-relaunch.png"
