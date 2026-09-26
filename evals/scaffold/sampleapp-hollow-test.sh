#!/usr/bin/env bash
# SampleApp on a feature branch that floors decrement at zero, with 2 new tests: one that fails
# when the change is reverted, and one hollow test that passes either way under a name that
# restates the behavior. The test-gate case expects the skill to catch the hollow one.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_root="$here"
while [ ! -f "$plugin_root/.claude-plugin/plugin.json" ]; do
  [ "$plugin_root" = "/" ] && { echo "scaffold: no plugin root above the case" >&2; exit 1; }
  plugin_root="$(dirname "$plugin_root")"
done
bash "$plugin_root/evals/scaffold/sampleapp.sh"

core=Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift
tests=Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift
git() { command git -c user.name=eval -c user.email=eval@example.invalid "$@"; }

git switch -q -c decrement-floor
perl -0pi -e 's/state\.count -= 1/state.count = max(0, state.count - 1)/' "$core"
perl -0pi -e 's/\n\}\s*\z/\n\n  \@Test("minus at zero keeps zero — catches the count going negative")\n  func floorAtZero() async {\n    let store = TestStore(initialState: CounterFeature.State(count: 0)) { CounterFeature() }\n\n    await store.send(.decrementButtonTapped)\n  }\n\n  \@Test("decrement works — catches decrement not working")\n  func decrementWorks() async {\n    let store = TestStore(initialState: CounterFeature.State(count: 5)) { CounterFeature() }\n\n    await store.send(.decrementButtonTapped) { \$0.count = 4 }\n  }\n}\n/' "$tests"
grep -q 'max(0, state.count - 1)' "$core" && grep -q decrementWorks "$tests" || { echo "scaffold: change did not apply" >&2; exit 1; }
git commit -qam "feat(counter): decrement stops at zero"
