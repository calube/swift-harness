#!/usr/bin/env bash
# Captures the batches a final pass drives for SampleApp's counter flow, in the shape `qa run`
# drives a recorded flow: 1 `snapshot` after each check, whose PNG is the video's frame. It runs the
# flow once passing and once failing, each after a `record start` with the `record stop` after it,
# the contact sheet of the passing video, and a flow that relaunches the app with its `open` before
# the `record start`. Each video is kept beside its batch.
# Usage, from the repository root: capture-frames.sh <swiftgate binary>
# The device comes from `swiftgate sim up` in examples/SampleApp, a clone under the `sim` lock, and
# `sim down` gives it back on exit, so no device another session uses is touched.
set -uo pipefail

swiftgate="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
cd "$here/../../../../../../examples/SampleApp" || exit 1

up="$("$swiftgate" sim up --json)" || { echo "sim up failed: $up" >&2; exit 1; }
read -r run udid session < <(/usr/bin/python3 -c \
  'import json,sys; d=json.loads(sys.argv[1]); print(d["runID"], d["udid"], d["session"])' "$up")
cleanup() {
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

batch recorded-pass
save record-stop agent-device record stop "${target[@]}"
cp "$work/video.mp4" "$here/recorded-pass.mp4"
save contact-sheet agent-device record contact-sheet "$work/video.mp4" \
  --out "$work/sheet.png" --json
/bin/rm -f "$work/video.mp4"
batch recorded-fail
save record-stop-after-fail agent-device record stop "${target[@]}"
cp "$work/video.mp4" "$here/recorded-fail.mp4"

# Leaves the counter at 1, so a frame from before the relaunch differs from the fresh launch's 0.
agent-device press 'id="counter.increment"' "${target[@]}" >/dev/null
batch relaunched-pass
save relaunched-record-stop agent-device record stop "${target[@]}"
cp "$work/relaunched.mp4" "$here/relaunched-pass.mp4"
