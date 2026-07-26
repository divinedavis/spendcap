#!/usr/bin/env bash
# Spendcap — capture App Store / portfolio screenshots from a signed-in session.
#
# Runs the MarketingScreenshots XCUITest and extracts its attachments as PNGs.
#
# Usage:
#   ./scripts/capture_screenshots.sh [output-dir]      # default: ./screenshots
#   SIMULATOR_ID=<udid> ./scripts/capture_screenshots.sh

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-screenshots}"
PROJECT="Spendcap.xcodeproj"
SCHEME="Spendcap"
DERIVED_DATA="${TMPDIR:-/tmp}/spendcap-screenshots-dd"
RESULT_BUNDLE="${TMPDIR:-/tmp}/spendcap-screenshots.xcresult"

SIMULATOR_ID="${SIMULATOR_ID:-}"
if [[ -z "$SIMULATOR_ID" ]]; then
    # Prefer a Pro device — App Store 6.9" screenshots come from this size.
    SIMULATOR_ID=$(xcrun simctl list devices available -j \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(iter([dev['udid'] for r in d['devices'].values() for dev in r if dev.get('name')=='iPhone 17 Pro' and dev.get('isAvailable')]), ''))")
fi
if [[ -z "$SIMULATOR_ID" ]]; then
    echo "error: no iPhone 17 Pro simulator available; pass SIMULATOR_ID=<udid>" >&2
    exit 1
fi
echo "==> simulator $SIMULATOR_ID"

if [[ -z "${SPENDCAP_TEST_EMAIL:-}" || -z "${SPENDCAP_TEST_PASSWORD:-}" ]]; then
    if creds=$(security find-generic-password -s spendcap-test-account -w 2>/dev/null); then
        export SPENDCAP_TEST_EMAIL=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['email'])")
        export SPENDCAP_TEST_PASSWORD=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['password'])")
    fi
fi
if [[ -z "${SPENDCAP_TEST_EMAIL:-}" ]]; then
    echo "error: no test account (keychain 'spendcap-test-account')" >&2
    exit 1
fi

# Xcode only forwards TEST_RUNNER_-prefixed vars into the runner (prefix stripped).
export TEST_RUNNER_SPENDCAP_TEST_EMAIL="$SPENDCAP_TEST_EMAIL"
export TEST_RUNNER_SPENDCAP_TEST_PASSWORD="$SPENDCAP_TEST_PASSWORD"
export TEST_RUNNER_SPENDCAP_SCREENSHOTS=1

rm -rf "$RESULT_BUNDLE"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -only-testing:SpendcapUITests/MarketingScreenshots \
    -skipPackagePluginValidation \
    test

mkdir -p "$OUT_DIR"
xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --test-id "MarketingScreenshots/testCaptureScreens()" \
    --output-path "$OUT_DIR" 2>/dev/null \
  || xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$OUT_DIR"

echo "==> screenshots in $OUT_DIR"
ls -1 "$OUT_DIR"
