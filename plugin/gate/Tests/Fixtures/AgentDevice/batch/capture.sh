#!/usr/bin/env bash
# Captures the batch flows `qa run` drives: SampleApp's counter flow with a snapshot, a screenshot
# and a second snapshot after each assertion, once passing and once failing at its `is` step.
# Usage, from the repository root: capture.sh <swiftgate binary>
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

record() {
  local name="$1"
  sed -e "s#/SCRATCH#$work#g" "$here/$name.steps.json" >"$work/$name.steps.json"
  agent-device batch --steps-file "$work/$name.steps.json" --on-error stop \
    --udid "$udid" --session "$session" --json >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$here/$name.status"
  scrub "$work/stdout" >"$here/$name.stdout"
  scrub "$work/stderr" >"$here/$name.stderr"
}

record pass
record fail
