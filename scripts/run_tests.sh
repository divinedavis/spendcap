#!/usr/bin/env bash
# Spendcap — full test sweep (unit + UI).
#
# Usage:
#   ./scripts/run_tests.sh                       # both targets, all tests
#   ./scripts/run_tests.sh unit                  # XCTest unit suite only
#   ./scripts/run_tests.sh ui                    # XCUITest sweep only
#   ./scripts/run_tests.sh unit MonthMathTests                       # one class
#   ./scripts/run_tests.sh ui SpendcapUITests/testHomeAndTrendsTabs  # one test
#
# Memory rule: this must pass before each TestFlight ship.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Spendcap.xcodeproj"
SCHEME="Spendcap"
UNIT_TARGET="SpendcapTests"
UI_TARGET="SpendcapUITests"
DERIVED_DATA="${TMPDIR:-/tmp}/spendcap-derived-data"

MODE="${1:-all}"
ONLY="${2:-}"

SIMULATOR_ID="${SIMULATOR_ID:-}"
if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID=$(xcrun simctl list devices booted -j 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(iter([dev['udid'] for runtime in d['devices'].values() for dev in runtime if dev.get('state')=='Booted']), ''))" 2>/dev/null || echo "")
fi
if [[ -z "$SIMULATOR_ID" ]]; then
    SIMULATOR_ID=$(xcrun simctl list devices available -j \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(iter([dev['udid'] for runtime in d['devices'].values() for dev in runtime if 'iPhone' in dev.get('name','') and dev.get('isAvailable')]), ''))")
fi
if [[ -z "$SIMULATOR_ID" ]]; then
    echo "error: no iPhone simulator available" >&2
    exit 1
fi
echo "==> simulator $SIMULATOR_ID"

# Pipe XCUITest creds in from the keychain so the UI suite can auto-sign-in.
if [[ -z "${SPENDCAP_TEST_EMAIL:-}" || -z "${SPENDCAP_TEST_PASSWORD:-}" ]]; then
    if creds=$(security find-generic-password -s spendcap-test-account -w 2>/dev/null); then
        export SPENDCAP_TEST_EMAIL=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['email'])" 2>/dev/null || true)
        export SPENDCAP_TEST_PASSWORD=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['password'])" 2>/dev/null || true)
    fi
fi

# Xcode only forwards host env vars prefixed with TEST_RUNNER_ into the
# XCUITest *runner* process (the prefix is stripped).
if [[ -n "${SPENDCAP_TEST_EMAIL:-}" ]]; then
    export TEST_RUNNER_SPENDCAP_TEST_EMAIL="$SPENDCAP_TEST_EMAIL"
    export TEST_RUNNER_SPENDCAP_TEST_PASSWORD="$SPENDCAP_TEST_PASSWORD"
fi

run_xcodebuild_test() {
    local only_target="$1"
    local args=(
        -project "$PROJECT"
        -scheme "$SCHEME"
        -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
        -derivedDataPath "$DERIVED_DATA"
        -skipPackagePluginValidation
        test
    )
    if [[ -n "$only_target" ]]; then
        if [[ -n "$ONLY" ]]; then
            # "Class" runs a whole class; "Class/testName" runs one test.
            args+=(-only-testing:"$only_target/$ONLY")
        else
            args+=(-only-testing:"$only_target")
        fi
    fi
    xcodebuild "${args[@]}"
}

case "$MODE" in
    unit)
        echo "==> running unit tests"
        run_xcodebuild_test "$UNIT_TARGET"
        ;;
    ui)
        echo "==> running UI tests"
        run_xcodebuild_test "$UI_TARGET"
        ;;
    all|*)
        echo "==> running unit tests"
        run_xcodebuild_test "$UNIT_TARGET"
        echo "==> running UI tests"
        run_xcodebuild_test "$UI_TARGET"
        ;;
esac

echo "==> tests passed"
