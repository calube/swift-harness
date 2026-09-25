#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/Xcresult/ from real `xcodebuild test` runs of the SampleApp's
# CounterFeature package on a throwaway clone of the pinned simulator.
# Run from the repository root: gate/Fixtures/xcresult/capture.sh [scenario...]
set -uo pipefail

root="$(pwd -P)"
out="$root/gate/Tests/Fixtures/Xcresult"
work="$(mktemp -d)"
derived="$root/.harness/DerivedData/xcresult-capture"
device_name="iPhone 17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
mkdir -p "$out" "$derived"

base="$(xcrun simctl list devices available --json | /usr/bin/python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices'].get('$runtime', [])
print(next(d['udid'] for d in devices if d['name'] == '$device_name'))")"
clone="$(xcrun simctl clone "$base" "swift-harness-$$-capture")"
cleanup() {
  xcrun simctl shutdown "$clone" >/dev/null 2>&1
  xcrun simctl delete "$clone" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# A scratch copy, so probe tests never touch the repository.
rsync -a --exclude .build --exclude .swiftpm "$root/examples/SampleApp/Packages/" "$work/Packages/"
package="$work/Packages/CounterFeature"
cp "$root/gate/Fixtures/xcresult/XcresultProbeTests.swift" \
  "$package/Tests/CounterUISnapshotTests/XcresultProbeTests.swift"

# A second copy whose probe does not compile.
broken="$work/Broken"
rsync -a "$work/Packages/" "$broken/"
sed -i '' 's/XCTAssertEqual(2 + 2, 4)/XCTAssertEqual(2 + 2, "4")/' \
  "$broken/CounterFeature/Tests/CounterUISnapshotTests/XcresultProbeTests.swift"

# read_parts <scenario> <bundle>
read_parts() {
  local scenario="$1" bundle="$2"
  for part in tests build-results; do
    local kind=(test-results "$part")
    [ "$part" = build-results ] && kind=(build-results)
    xcrun xcresulttool get "${kind[@]}" --path "$bundle" \
      >"$work/$scenario.$part.json" 2>"$work/$scenario.$part.stderr"
    local status=$?
    # Captured verbatim apart from machine paths; a failing read is recorded as its stderr.
    if [ "$status" -eq 0 ]; then
      scrub "$work/$scenario.$part.json" >"$out/$scenario.$part.json"
      rm -f "$out/$scenario.$part.stderr" "$out/$scenario.$part.status"
    else
      scrub "$work/$scenario.$part.stderr" >"$out/$scenario.$part.stderr"
      echo "$status" >"$out/$scenario.$part.status"
      rm -f "$out/$scenario.$part.json"
    fi
  done
}

# Machine paths, the clone's identity, and the machine's device list (in "no destination" errors)
# are replaced; everything else is verbatim.
scrub() {
  sed -e "s#/private$work#/SCRATCH#g" -e "s#$work#/SCRATCH#g" -e "s#$root#/REPO#g" -e "s#$clone#CLONE-UDID#g" \
    -e "s#swift-harness-$$-capture#swift-harness-PID-capture#g" "$1" |
    perl -pe 's/(\\n\\n\\tAvailable destinations for)(?:[^"\\]|\\.)*/$1 <elided by capture.sh>/'
}

# capture <scenario> <package dir> <destination> <only-testing...>
capture() {
  local scenario="$1" package="$2" destination="$3"
  shift 3
  local only=()
  for test in "$@"; do only+=("-only-testing:CounterUISnapshotTests/$test"); done
  local bundle="$work/$scenario.xcresult"
  local started=$SECONDS
  (cd "$package" && TEST_RUNNER_SNAPSHOT_TESTING_RECORD="${RECORD:-never}" xcodebuild test \
    -scheme CounterFeature-Package -destination "$destination" -derivedDataPath "$derived/${DERIVED_KEY:-main}" \
    -resultBundlePath "$bundle" -skipMacroValidation "${only[@]}" \
    >"$work/$scenario.xcodebuild.log" 2>&1)
  echo "$?" >"$out/$scenario.status"
  echo "$scenario: exit $(cat "$out/$scenario.status") in $((SECONDS - started))s" >&2
  read_parts "$scenario" "$bundle"
}

scenarios=("$@")
[ ${#scenarios[@]} -eq 0 ] && scenarios=(pass fail skip crash zero no-destination build-error record missing-bundle)
for scenario in "${scenarios[@]}"; do
  case "$scenario" in
  pass) capture pass "$package" "id=$clone" CounterViewSnapshotTests ProbePassXCTests ;;
  fail) capture fail "$package" "id=$clone" ProbeFailXCTests ProbeFailSwiftTests ProbePassXCTests ;;
  skip) capture skip "$package" "id=$clone" ProbeSkipXCTests ProbeSkipSwiftTests ;;
  crash) capture crash "$package" "id=$clone" ProbeCrashXCTests ProbeCrashSwiftTests ProbePassXCTests ;;
  zero) capture zero "$package" "id=$clone" NoSuchSuite ;;
  no-destination) capture no-destination "$package" "id=00000000-0000-0000-0000-000000000000" ProbePassXCTests ;;
  build-error) DERIVED_KEY=broken capture build-error "$broken/CounterFeature" "id=$clone" ProbePassXCTests ;;
  record) RECORD=all capture record "$package" "id=$clone" CounterViewSnapshotTests ProbeFailXCTests ;;
  missing-bundle) read_parts missing-bundle "$work/missing.xcresult" ;;
  *) echo "unknown scenario $scenario" >&2 && exit 2 ;;
  esac
done
