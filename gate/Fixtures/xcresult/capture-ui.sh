#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/Xcresult/ui-pass.* from a real T3 run of the SampleApp's app
# scheme (its one XCUITest, CounterFlowUITests) on a throwaway clone of the pinned simulator.
# Run from the repository root: gate/Fixtures/xcresult/capture-ui.sh
set -uo pipefail

root="$(pwd -P)"
out="$root/gate/Tests/Fixtures/Xcresult"
(cd examples/SampleApp && "$root/bin/swiftgate" test --tier t3 --json >/dev/null)
bundle="$(ls -td examples/SampleApp/.harness/runs/*/t3/app-SampleApp.xcresult | head -1)"
xcrun xcresulttool get test-results tests --path "$bundle" |
  sed -e "s#$root#/REPO#g" -e 's#swift-harness-[0-9]*-[a-z0-9]*#swift-harness-PID-TOKEN#g' \
    -e 's#"deviceId" : "[0-9A-F-]*"#"deviceId" : "CLONE-UDID"#' \
    >"$out/ui-pass.tests.json"
xcrun xcresulttool get build-results --path "$bundle" | sed -e "s#$root#/REPO#g" \
  >"$out/ui-pass.build-results.json"
