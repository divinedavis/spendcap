#!/usr/bin/env bash
# Spendcap — build, install, and launch in a simulator to prove the app
# actually starts. Tests passing does not prove this: XCUITest launches the app
# through its own harness, so a bundle that fails a cold `simctl launch` can
# still show a green suite.
#
# Memory rule: smoke-test a launch before every TestFlight ship.
#
# Usage:
#   ./scripts/smoke_test.sh                  # auto-pick a simulator
#   SIMULATOR_ID=<udid> ./scripts/smoke_test.sh

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Spendcap.xcodeproj"
SCHEME="Spendcap"
BUNDLE_ID="com.divinedavis.spendcap"
DERIVED_DATA="build.nosync/smoke"

SIMULATOR_ID="${SIMULATOR_ID:-}"
if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID=$(xcrun simctl list devices booted -j 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(iter([dev['udid'] for r in d['devices'].values() for dev in r if dev.get('state')=='Booted']), ''))" 2>/dev/null || echo "")
fi
if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID=$(xcrun simctl list devices available -j \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(iter([dev['udid'] for r in d['devices'].values() for dev in r if 'iPhone' in dev.get('name','') and dev.get('isAvailable')]), ''))")
fi
if [[ -z "$SIMULATOR_ID" ]]; then
    echo "error: no iPhone simulator available" >&2
    exit 1
fi
echo "==> simulator $SIMULATOR_ID"

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1 || true

# ENABLE_DEBUG_DYLIB=NO is REQUIRED. Xcode 26's default Debug build produces a
# stub executable that loads <App>.debug.dylib; that layout launches from Xcode
# but `simctl launch` rejects it with:
#   "The request was denied by service delegate (SBMainWorkspace)"
# which looks like a crash and is not one. See the memory note
# reference_ios_simctl_debug_dylib.
echo "==> building for simulator"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    ENABLE_DEBUG_DYLIB=NO \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

APP=$(find "$DERIVED_DATA/Build/Products" -maxdepth 3 -name 'Spendcap.app' | head -1)
if [[ -z "$APP" ]]; then
    echo "error: built Spendcap.app not found under $DERIVED_DATA" >&2
    exit 1
fi

echo "==> installing"
xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIMULATOR_ID" "$APP"

echo "==> launching"
PID=$(xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" | sed -E 's/.*: ([0-9]+)$/\1/')
if [[ -z "$PID" ]]; then
    echo "error: launch did not report a pid" >&2
    exit 1
fi

# A crash-on-launch still returns a pid, so confirm the process is alive once
# the first frames have had time to render.
#
# Poll rather than checking once: straight after a UI-test run the simulator is
# still settling and `simctl spawn` can transiently return nothing, which a
# single check reports as a crash. A gate that cries wolf gets ignored, so it
# must only fail when the app is genuinely absent.
CRASH_GLOB=(~/Library/Logs/DiagnosticReports/Spendcap*)
crash_seen() { [[ -e "${CRASH_GLOB[0]}" ]] && \
    [[ -n "$(find ~/Library/Logs/DiagnosticReports -name 'Spendcap*' -newermt '-2 minutes' 2>/dev/null)" ]]; }

alive=0
for _ in $(seq 1 12); do   # up to ~24s
    if xcrun simctl spawn "$SIMULATOR_ID" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
        alive=1
        break
    fi
    # A fresh crash report is definitive — stop waiting.
    if crash_seen; then break; fi
    sleep 2
done

if [[ "$alive" -ne 1 ]]; then
    echo "error: $BUNDLE_ID is not running after launch — crashed on start" >&2
    if crash_seen; then
        echo "recent crash reports:" >&2
        find ~/Library/Logs/DiagnosticReports -name 'Spendcap*' -newermt '-2 minutes' 2>/dev/null | head -3 >&2
    else
        echo "(no crash report found — the simulator may be wedged; try re-running)" >&2
    fi
    exit 1
fi

echo "==> smoke test passed (pid $PID, still running)"
