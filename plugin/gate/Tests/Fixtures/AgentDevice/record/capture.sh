#!/usr/bin/env bash
# Captures what a final pass calls around 1 flow: the app log stream, SampleApp's driven counter
# flow as a batch that starts with `record start`, once passing and once failing, the `record stop`
# after each and the contact sheet of the passing video, a `record start` beside a recorder outside
# the harness, the network dump, the unified log for the app's subsystem, and the app's data
# container.
# Usage, from the repository root: capture.sh <swiftgate binary>
# The device comes from `swiftgate sim up` in examples/SampleApp, a clone under the `sim` lock, and
# `sim down` gives it back on exit, so no device another session uses is touched.
set -uo pipefail

swiftgate="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
bundle="com.example.SampleApp"
cd "$here/../../../../../../examples/SampleApp" || exit 1

since="$(date '+%Y-%m-%d %H:%M:%S')"
up="$("$swiftgate" sim up --json)" || { echo "sim up failed: $up" >&2; exit 1; }
read -r run udid session < <(/usr/bin/python3 -c \
  'import json,sys; d=json.loads(sys.argv[1]); print(d["runID"], d["udid"], d["session"])' "$up")
outside=""
cleanup() {
  [ -n "$outside" ] && kill -INT "$outside" 2>/dev/null && wait "$outside" 2>/dev/null
  "$swiftgate" sim down "$run" >&2
  /bin/rm -rf "$work"
}
trap cleanup EXIT

scrub() {
  sed -e "s#$work#/SCRATCH#g" -e "s#$HOME#/HOME#g" -e "s#$udid#UDID#g" -e "s#$session#SESSION#g" "$1"
}

save() {
  local name="$1"
  shift
  "$@" >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.status"
  scrub "$work/stdout" >"$here/$name.stdout"
  scrub "$work/stderr" >"$here/$name.stderr"
}

target=(--udid "$udid" --session "$session" --json)

batch() {
  local name="$1"
  sed -e "s#/SCRATCH#$work#g" "$here/$name.steps.json" >"$work/$name.steps.json"
  save "$name" agent-device batch --steps-file "$work/$name.steps.json" --on-error stop \
    "${target[@]}"
}

save logs-start agent-device logs start "${target[@]}"
batch recorded-pass
save record-stop agent-device record stop "${target[@]}"
save contact-sheet agent-device record contact-sheet "$work/video.mp4" \
  --out "$work/sheet.png" --json
batch recorded-fail
save record-stop-after-fail agent-device record stop "${target[@]}"

# Another recorder on the Mac: simctl's own, as a session outside the harness would run it.
xcrun simctl io "$udid" recordVideo "$work/outside.mp4" >/dev/null 2>&1 &
outside=$!
sleep 3
save record-start-beside-outside agent-device record start "$work/beside.mp4" "${target[@]}"
agent-device record stop "${target[@]}" >/dev/null 2>&1
kill -INT "$outside" && wait "$outside" 2>/dev/null
outside=""

save logs-stop agent-device logs stop "${target[@]}"
save logs-path agent-device logs path "${target[@]}"
save network-dump agent-device network dump 25 --include headers "${target[@]}"
save app-container xcrun simctl get_app_container "$udid" "$bundle" data
save log-show xcrun simctl spawn "$udid" log show --style compact --info --debug \
  --predicate "subsystem == \"$bundle\"" --start "$since"
