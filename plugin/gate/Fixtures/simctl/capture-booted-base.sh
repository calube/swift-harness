#!/usr/bin/env bash
# Re-captures what simctl does when the base device is booted: `clone` refuses it, and `create`
# makes a fresh device instead. Every call targets a throwaway base this script creates, boots and
# deletes, so a device another session or tool is using is never shut down or deleted.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
out="$here/../../Tests/Fixtures/Simctl"
work="$(cd "$(mktemp -d)" && pwd -P)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"

record() {
  local name="$1"
  shift
  xcrun simctl "$@" >"$out/$name.stdout" 2>"$work/stderr"
  echo "$?" >"$out/$name.status"
  sed -e "s#$work#/SCRATCH#g" "$work/stderr" >"$out/$name.stderr"
}

base="$(xcrun simctl create "swiftgate capture base" "$type" "$runtime")"
cleanup() {
  for udid in "$base" $(xcrun simctl list devices --json | /usr/bin/python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['name'].startswith('swift-harness-$$-'): print(d['udid'])"); do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    xcrun simctl delete "$udid" >/dev/null 2>&1
  done
  rm -rf "$work"
}
trap cleanup EXIT

xcrun simctl bootstatus "$base" -b >/dev/null
record clone-booted clone "$base" "swift-harness-$$-booted"
record create create "swift-harness-$$-created" "$type" "$runtime"
record list-devices-booted-base list devices --json
