#!/usr/bin/env bash
# Re-captures gate/Tests/Fixtures/Xcresult/app-build-{pass,error}.build-results.json from real
# `swiftgate check --tier fast --app-build` runs over a scratch git copy of the SampleApp: once as
# committed, once with a type error committed into the app target's own source.
# Run from anywhere: plugin/gate/Fixtures/xcresult/capture-app-build.sh
set -uo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
repo="$(cd "$plugin/.." && pwd -P)"
out="$plugin/gate/Tests/Fixtures/Xcresult"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap '/bin/rm -rf "$scratch"' EXIT
app="$scratch/SampleApp"

rsync -a --exclude .harness --exclude .build --exclude DerivedData \
  "$repo/examples/SampleApp/" "$app/"
git -C "$app" init -q -b main
git -C "$app" add -A
git -C "$app" -c user.name=capture -c user.email=capture@example.com commit -q -m base

capture() {
  local name="$1" base="$2"
  (cd "$app" && "$plugin/bin/swiftgate" check --tier fast --base "$base" --app-build --json \
    >"$scratch/$name.report.json")
  echo "$name: $(grep -o '"verdict" *: *"[A-Za-z]*"' "$scratch/$name.report.json" | tail -1)"
  grep -o '"ruleID" *: *"app-build[^"]*"' "$scratch/$name.report.json"
  local bundle
  bundle="$(ls -td "$app"/.harness/runs/*/app-build/SampleApp.xcresult | head -1)"
  # xcodebuild spells a /private/var scratch path as /var.
  xcrun xcresulttool get build-results --path "$bundle" |
    sed -e "s#$scratch#/SCRATCH#g" -e "s#${scratch#/private}#/SCRATCH#g" \
    >"$out/app-build-$name.build-results.json"
}

capture pass HEAD

cat >>"$app/App/SampleApp.swift" <<'SWIFT'

extension SampleApp {
  static let broken: Int = "not a number"
}
SWIFT
git -C "$app" -c user.name=capture -c user.email=capture@example.com commit -q -am broken

capture error HEAD~1
