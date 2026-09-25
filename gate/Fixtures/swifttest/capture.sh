#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/SwiftTest/ from real `swift test` runs of XUnitProbe.
# Run from the repository root: gate/Fixtures/swifttest/capture.sh
set -uo pipefail

root="$(pwd -P)"
probe="$root/gate/Fixtures/swifttest/XUnitProbe"
probe_path="/REPO/gate/Fixtures/swifttest/XUnitProbe"
out="$root/gate/Tests/Fixtures/SwiftTest"
work="$(mktemp -d)"
mkdir -p "$out"

# capture <scenario> <package dir> <path it is recorded as> <filter> [extra swift test args...]
capture() {
  local scenario="$1" dir="$2" recorded="$3" filter="$4"
  shift 4
  (cd "$dir" && swift test --parallel "$@" --xunit-output "$work/$scenario.xml" --filter "$filter" \
    >"$work/$scenario.stdout" 2>"$work/$scenario.stderr")
  echo "$?" >"$work/$scenario.status"
  for file in "$scenario.xml" "$scenario-swift-testing.xml" "$scenario.stdout" "$scenario.stderr" \
    "$scenario.status"; do
    if [ -f "$work/$file" ]; then
      sed -e "s#$dir#$recorded#g" -e "s#$root#/REPO#g" "$work/$file" >"$out/$file"
    else
      rm -f "$out/$file"
    fi
  done
}

(cd "$probe" && swift build --build-tests >/dev/null)

capture pass "$probe" "$probe_path" 'ProbeTests\.Pass' --enable-code-coverage
sed -e "s#$root#/REPO#g" "$(cd "$probe" && swift test --show-codecov-path)" >"$out/pass-codecov.json"
# Coverage of a run that executes no test: every Probe line is instrumented but none ran.
(cd "$probe" && swift test --parallel --enable-code-coverage --filter '^EmptyTests\.' >/dev/null 2>&1)
sed -e "s#$root#/REPO#g" "$(cd "$probe" && swift test --show-codecov-path)" >"$out/zero-codecov.json"
capture fail "$probe" "$probe_path" 'ProbeTests\.Fail'
capture skip "$probe" "$probe_path" 'ProbeTests\.Skip'
capture crash "$probe" "$probe_path" 'ProbeTests\.Crash'
capture zero "$probe" "$probe_path" '^EmptyTests\.'

# A compile error in the code under test: copy without build output, break one line.
broken="$work/broken"
mkdir -p "$broken"
rsync -a --exclude .build "$probe/" "$broken/"
sed -i '' 's/value \* 2/value * "2"/' "$broken/Sources/Probe/Probe.swift"
capture build-error "$(cd "$broken" && pwd -P)" "$probe_path" 'ProbeTests\.Pass'

# Proof scenarios: the passing tests run against the code under test with its change reverted.
# `reverted`: the source still compiles but computes the old (wrong) result.
reverted="$work/reverted"
mkdir -p "$reverted"
rsync -a --exclude .build "$probe/" "$reverted/"
sed -i '' 's/value \* 2/value * 3/' "$reverted/Sources/Probe/Probe.swift"
capture reverted "$(cd "$reverted" && pwd -P)" "$probe_path" 'ProbeTests\.Pass'

# `compile-only`: the reverted source lacks the function the tests call.
missing="$work/missing"
mkdir -p "$missing"
rsync -a --exclude .build "$probe/" "$missing/"
sed -i '' 's/public func double/func removedDouble/' "$missing/Sources/Probe/Probe.swift"
capture compile-only "$(cd "$missing" && pwd -P)" "$probe_path" 'ProbeTests\.Pass'

# An environment failure: build output moved to another path, so its module cache is stale.
moved="$work/moved"
mkdir -p "$moved"
rsync -a "$probe/" "$moved/"
capture stale-module-cache "$(cd "$moved" && pwd -P)" /MOVED/XUnitProbe 'ProbeTests\.Pass'

rm -rf "$work"
