#!/usr/bin/env bash
# Captures typing into a SwiftUI `.searchable` field, whose UISearchBar text field carries no
# accessibility identifier: a `fill` on the id the list carries, with and without a `press` first,
# then a `fill` or `press` and `type` that select the field by its role or its prompt, in the
# default bottom placement and in a navigation bar drawer, and a strict absence wait written with a
# `selector` key, which waits for the element to appear instead.
# Usage, from anywhere: capture.sh
# It compiles SearchableProbe.swift for the simulator, then creates, boots and deletes its own
# throwaway device, so a device another session or tool is using is never touched.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
session="swiftgate-capture-searchable"
app="$work/SearchableProbe.app"

mkdir -p "$app"
cp "$here/Info.plist" "$app/Info.plist"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios18.0-simulator \
  "$here/SearchableProbe.swift" -o "$app/SearchableProbe" || exit 1
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

for name in fill-list-id press-then-fill-list-id fill-search-field fill-search-prompt \
  press-then-type-search-field fill-search-field-drawer wait-absent-selector-key; do
  agent-device batch --steps-file "$here/$name.steps.json" --on-error stop \
    --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.status"
  scrub "$work/stdout" >"$here/$name.stdout"
  scrub "$work/stderr" >"$here/$name.stderr"
done
