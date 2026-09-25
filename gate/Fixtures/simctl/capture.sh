#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/Simctl/ from real `xcrun simctl` calls against a throwaway clone
# of the pinned simulator (iPhone 17, iOS 26.2). Run from the repository root.
set -uo pipefail

out="$(pwd -P)/gate/Tests/Fixtures/Simctl"
work="$(cd "$(mktemp -d)" && pwd -P)"
mkdir -p "$out"
missing="00000000-0000-0000-0000-000000000000"

# record <name> <simctl args...>: stdout, stderr and exit status of one call, verbatim apart from
# the scratch directory path.
record() {
  local name="$1"
  shift
  xcrun simctl "$@" >"$out/$name.stdout" 2>"$work/stderr"
  echo "$?" >"$out/$name.status"
  sed -e "s#$work#/SCRATCH#g" "$work/stderr" >"$out/$name.stderr"
}

base="$(xcrun simctl list devices available --json | /usr/bin/python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices'].get('com.apple.CoreSimulator.SimRuntime.iOS-26-2', [])
print(next(d['udid'] for d in devices if d['name'] == 'iPhone 17'))")"

record clone clone "$base" "swift-harness-$$-capture"
clone="$(cat "$out/clone.stdout")"
record list-devices list devices --json
record bootstatus bootstatus "$clone" -b
record launch launch "$clone" com.apple.Preferences
record install-missing install "$clone" "$work/Missing.app"
record shutdown shutdown "$clone"
record delete delete "$clone"
record clone-missing clone "$missing" "swift-harness-$$-missing"
record delete-missing delete "$missing"
rm -rf "$work"
