#!/usr/bin/env bash
# Captures which launches a qa flow row makes: `sim up` opens the app, then the row's batch starts
# a recording and relaunches the app in the flow's scenario. The probe app appends each launch's
# arguments to Documents/launches.log. Run 1 opens with no arguments, as sim up did for every row;
# run 2 opens with the flow's first `open` arguments; run 3 opens a session with no app, which
# the batch's `record start` refuses.
# Usage, from anywhere: capture.sh
# It compiles LaunchProbe.swift for the simulator, then creates, boots and deletes its own
# throwaway device, so a device another session or tool is using is never touched.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
bundle="com.example.LaunchProbe"
app="$work/LaunchProbe.app"

mkdir -p "$app"
cp "$here/Info.plist" "$app/Info.plist"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios18.0-simulator \
  "$here/LaunchProbe.swift" -o "$app/LaunchProbe" || exit 1
codesign -s - --force "$app" >/dev/null 2>&1 || exit 1

udid="$(xcrun simctl create "agent-device-capture-$$" "$type" "$runtime")" || exit 1
cleanup() {
  for session in live-first scenario-first app-less; do
    agent-device close --udid "$udid" --session "swiftgate-capture-$session" --json >/dev/null 2>&1
  done
  xcrun simctl shutdown "$udid" >/dev/null 2>&1
  xcrun simctl delete "$udid" >/dev/null 2>&1
  /bin/rm -rf "$work"
}
trap cleanup EXIT

xcrun simctl boot "$udid" >/dev/null 2>&1
xcrun simctl bootstatus "$udid" -b >/dev/null

scrub() {
  sed -e "s#$work#/SCRATCH#g" -e "s#$HOME#/HOME#g" -e "s#$udid#UDID#g" "$1"
}

# 1 run: a fresh install, `open` with the given launch arguments (none for an app-less session),
# then the row's batch: `record start`, the flow's relaunch in its scenario, a wait, `record stop`.
run() {
  local name="$1"
  shift
  local session="swiftgate-capture-$name"
  xcrun simctl uninstall "$udid" "$bundle" >/dev/null 2>&1
  xcrun simctl install "$udid" "$app" || exit 1
  agent-device open "$@" --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.open.status"
  scrub "$work/stdout" >"$here/$name.open.stdout"
  cat >"$work/$name.steps.json" <<STEPS
[{"command": "record", "input": {"action": "start", "path": "$work/$name.mp4"}},
 {"command": "open", "input": {"app": "$bundle", "relaunch": true, "launchArgs": ["-harness-scenario", "success"]}},
 {"command": "wait", "input": {"kind": "selector", "selector": "id=\"probe.arguments\"", "timeoutMs": 5000}},
 {"command": "record", "input": {"action": "stop"}}]
STEPS
  agent-device batch --steps-file "$work/$name.steps.json" --on-error stop \
    --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.status"
  scrub "$work/stdout" >"$here/$name.stdout"
  scrub "$work/stderr" >"$here/$name.stderr"
  local container
  container="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
  cat "$container/Documents/launches.log" >"$here/$name.launches.txt" 2>/dev/null \
    || : >"$here/$name.launches.txt"
  # A session holds its device until it closes, so the next run's `open` would be refused.
  agent-device close --udid "$udid" --session "$session" --json >/dev/null 2>&1
}

run live-first "$bundle"
run scenario-first "$bundle" --launch-args -harness-scenario --launch-args success
run app-less
