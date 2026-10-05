#!/usr/bin/env bash
# Captures a final pass's batch for a flow that starts by relaunching the app: the `open` runs
# first and `record start` second, so the video opens on the fresh launch, then the `record stop`.
# Usage, from the repository root: capture-relaunched.sh <swiftgate binary>
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

# Leaves the counter at 1, so a frame from before the relaunch differs from the fresh launch's 0.
agent-device press 'id="counter.increment"' "${target[@]}" >/dev/null
sed -e "s#/SCRATCH#$work#g" "$here/relaunched-pass.steps.json" >"$work/steps.json"
save relaunched-pass agent-device batch --steps-file "$work/steps.json" --on-error stop \
  "${target[@]}"
save relaunched-record-stop agent-device record stop "${target[@]}"
