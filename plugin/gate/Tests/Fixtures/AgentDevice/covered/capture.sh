#!/usr/bin/env bash
# Captures a batch that `agent-device` stops with a failure reason outside the ones swiftgate
# names: a `press` on a SwiftUI toggle whose label is hidden, so its accessibility node is covered
# by its own `UISwitch` (`covered_by_interactive_descendants`).
# Usage, from the repository root: capture.sh <swiftgate binary>
# It applies change.diff to examples/SampleApp for the run and reverts it on exit. The device
# comes from `swiftgate sim up`, a clone under the `sim` lock, and `sim down` gives it back.
set -uo pipefail

swiftgate="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
here="$(cd "$(dirname "$0")" && pwd -P)"
work="$(cd "$(mktemp -d)" && pwd -P)"
repo="$(cd "$here/../../../../../.." && pwd -P)"
git -C "$repo" apply "$here/change.diff" || exit 1
cd "$repo/examples/SampleApp" || exit 1

run=""
cleanup() {
  [ -n "$run" ] && "$swiftgate" sim down "$run" >&2
  git -C "$repo" apply -R "$here/change.diff"
  /bin/rm -rf "$work"
}
trap cleanup EXIT

up="$("$swiftgate" sim up --json)" || { echo "sim up failed: $up" >&2; exit 1; }
read -r run udid session < <(/usr/bin/python3 -c \
  'import json,sys; d=json.loads(sys.argv[1]); print(d["runID"], d["udid"], d["session"])' "$up")

scrub() {
  sed -e "s#$work#/SCRATCH#g" -e "s#$HOME#/HOME#g" -e "s#$udid#UDID#g" -e "s#$session#SESSION#g" "$1"
}

name=press-switch
sed -e "s#/SCRATCH#$work#g" "$here/$name.steps.json" >"$work/$name.steps.json"
agent-device batch --steps-file "$work/$name.steps.json" --on-error stop \
  --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
echo "$?" >"$here/$name.status"
scrub "$work/stdout" >"$here/$name.stdout"
scrub "$work/stderr" >"$here/$name.stderr"
