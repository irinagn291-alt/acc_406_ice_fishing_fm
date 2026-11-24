#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GF_SIMULATOR_UDID:?Launch this script with simulator_pool.py}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
device="${1:?QA run name}"
shift
evidence="$PWD/QA/$device"
derived="$PWD/.build/$device"
if [[ -e "$evidence/run.xcresult" ]]; then
    python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["result"] != "Passed")' "$evidence/summary.json"
    exit
fi
mkdir -p "$evidence" "$derived"
xcrun simctl boot "$GF_SIMULATOR_UDID"
xcrun simctl bootstatus "$GF_SIMULATOR_UDID" -b
xcrun simctl status_bar "$GF_SIMULATOR_UDID" override --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100 || true

finish_recording() {
    if [[ -n "${recorder:-}" ]]; then
        kill -INT "$recorder" 2>/dev/null || true
        wait "$recorder" || true
        recorder=
    fi
}
trap finish_recording EXIT
if [[ "${ICE_QA_VIDEO:-0}" == 1 ]]; then
    python3 -c 'import time; print(time.time())' > "$derived/recording-start.txt"
    xcrun simctl io "$GF_SIMULATOR_UDID" recordVideo --codec=h264 --force "$derived/screen.mov" \
        > "$evidence/recording.log" 2>&1 &
    recorder=$!
fi
if [[ "${ICE_QA_CAMPAIGN:-0}" != 1 ]]; then
    set -- -skip-testing:ExpeditionTests/ExpeditionTests/test07FreshCampaign "$@"
fi
xcodebuild -project "Ice Fishing FM.xcodeproj" -scheme "Ice Fishing FM" -derivedDataPath "$derived" \
    -destination "id=$GF_SIMULATOR_UDID" -parallel-testing-enabled NO -resultBundlePath "$evidence/run.xcresult" \
    CODE_SIGNING_ALLOWED=NO test "$@" > "$evidence/xcodebuild.log" 2>&1 || status=$?
finish_recording
if [[ -d "$evidence/run.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$evidence/run.xcresult" --format json > "$evidence/summary.json"
    xcrun xcresulttool export attachments --path "$evidence/run.xcresult" --output-path "$evidence/attachments"
    python3 QA/export_evidence.py "$evidence" "$derived"
fi
exit "${status:-0}"
