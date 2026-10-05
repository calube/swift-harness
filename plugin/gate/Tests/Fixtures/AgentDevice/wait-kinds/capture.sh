#!/usr/bin/env bash
# Captures each `wait` kind in the input key agent-device reads it from, and a `kind: absent` wait
# whose target sits in `selector`, which agent-device runs as a wait for the element to appear.
# Usage, from anywhere: capture.sh
# It compiles WaitProbe.swift for the simulator, then creates, boots and deletes its own
# throwaway device, so a device another session or tool is using is never touched.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
session="swiftgate-capture-wait-kinds"
app="$work/WaitProbe.app"

mkdir -p "$app"
cp "$here/Info.plist" "$app/Info.plist"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios18.0-simulator \
  "$here/WaitProbe.swift" -o "$app/WaitProbe" || exit 1
codesign -s - --force "$app" >/dev/null 2>&1 || exit 1

udid="$(xcrun simctl create "agent-device-capture-$$" "$type" "$runtime")" || exit 1
cleanup() {
  agent-device close --udid "$udid" --session "$session" --json >/dev/null 2>&1
  xcrun simctl shutdown "$udid" >/dev/null 2>&1
  xcrun simctl delete "$udid" >/dev/null 2>&1
  /bin/rm -rf "$work"
}
trap cleanup EXIT

xcrun simctl boot "$udid" >/dev/null 2>&1
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app" || exit 1

scrub() {
  sed -e "s#$work#/SCRATCH#g" -e "s#$HOME#/HOME#g" -e "s#$udid#UDID#g" "$1"
}

for name in kinds absent-in-selector absent-in-selector-while-loading; do
  agent-device batch --steps-file "$here/$name.steps.json" --on-error stop \
    --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.status"
  scrub "$work/stdout" >"$here/$name.stdout"
  scrub "$work/stderr" >"$here/$name.stderr"
done
