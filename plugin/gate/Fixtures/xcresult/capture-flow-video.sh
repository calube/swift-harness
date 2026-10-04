#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/Xcresult/activities/ from real `swiftgate test --tier t3` runs
# over a scratch git copy of the SampleApp, whose test plan keeps every UI test's screen recording:
# `pass` as committed, `fail` with the counter test expecting the wrong count, and `no-video` with
# the plan deleting attachments of passing tests. Each run goes on the harness's own simulator
# clone. Per scenario it saves the test tree, each UI test's activities, and the attachments
# manifest; the MP4s stay out of the repository.
# Run from anywhere: plugin/gate/Fixtures/xcresult/capture-flow-video.sh
# SWIFTGATE=<binary> runs that build instead of the shim, so gate sources may change meanwhile.
set -uo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
repo="$(cd "$plugin/.." && pwd -P)"
out="$plugin/gate/Tests/Fixtures/Xcresult/activities"
swiftgate="${SWIFTGATE:-$plugin/bin/swiftgate}"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap '/bin/rm -rf "$scratch"' EXIT
app="$scratch/SampleApp"

rsync -a --exclude .harness --exclude .build --exclude DerivedData \
  "$repo/examples/SampleApp/" "$app/"
git -C "$app" init -q -b main
git -C "$app" add -A
git -C "$app" -c user.name=capture -c user.email=capture@example.com commit -q -m base

scrub() {
  sed -e "s#$scratch#/SCRATCH#g" -e "s#${scratch#/private}#/SCRATCH#g" \
    -e 's#swift-harness-[0-9]*-[a-z0-9]*#swift-harness-PID-TOKEN#g' \
    -e 's#"deviceId" : "[0-9A-F-]*"#"deviceId" : "CLONE-UDID"#'
}

capture() {
  local name="$1" dir="$out/$1"
  mkdir -p "$dir"
  (cd "$app" && "$swiftgate" test --tier t3 --json >"$scratch/$name.report.json")
  echo "$name: $(grep -o '"verdict" *: *"[A-Za-z]*"' "$scratch/$name.report.json" | tail -1)"
  local bundle
  bundle="$(ls -td "$app"/.harness/runs/*/t3/app-SampleApp.xcresult | head -1)"
  xcrun xcresulttool get test-results tests --path "$bundle" | scrub >"$dir/tests.json"
  local id
  for id in CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount\(\) \
    CounterFlowUITests/testFixedFactScenarioShowsItsFactWithoutNetwork\(\); do
    local method="${id#*/}"
    xcrun xcresulttool get test-results activities --test-id "$id" --path "$bundle" |
      scrub >"$dir/${method%()}.activities.json"
  done
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$scratch/$name-attachments" \
    >/dev/null
  scrub <"$scratch/$name-attachments/manifest.json" >"$dir/manifest.json"
  ls -l "$scratch/$name-attachments"
}

capture pass

sed -i '' 's/XCTAssertEqual(value.label, "1")/XCTAssertEqual(value.label, "7")/' \
  "$app/UITests/CounterFlowUITests.swift"
git -C "$app" -c user.name=capture -c user.email=capture@example.com commit -q -am fail
capture fail
git -C "$app" revert --no-edit HEAD >/dev/null

sed -i '' 's/"uiTestingScreenshotsLifetime" : "keepAlways"/"uiTestingScreenshotsLifetime" : "deleteOnSuccess"/' \
  "$app/SampleApp.xctestplan"
git -C "$app" -c user.name=capture -c user.email=capture@example.com commit -q -am no-video
capture no-video
