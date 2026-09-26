#!/usr/bin/env bash
# SampleApp with work in progress, for routing prompts that say "my change", "my branch" or
# "staged": a feature branch with 1 committed change over main, plus 1 staged edit. The change
# adds a fact-dismiss action, which no routing prompt asks for.
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

git switch -q -c fact-dismiss
perl -0pi -e 's/    case factFailed\n  \}/    case factFailed\n    case factDismissButtonTapped\n  }/' "$core"
perl -0pi -e 's/(      case \.factFailed:\n        state\.isLoadingFact = false\n        return \.none\n)/$1\n      \/\/ Dismiss the fact.\n      case .factDismissButtonTapped:\n        \/\/ Set the fact to nil so it goes away.\n        state.fact = nil\n        return .none\n/' "$core"
perl -0pi -e 's/\n\}\s*\z/\n\n  \@Test("dismissing a fact hides it — catches the fact staying on screen")\n  func dismissFact() async {\n    let store = TestStore(initialState: CounterFeature.State(fact: "shown")) { CounterFeature() }\n\n    await store.send(.factDismissButtonTapped) { \$0.fact = nil }\n  }\n}\n/' "$tests"
grep -q factDismissButtonTapped "$core" && grep -q dismissFact "$tests" || { echo "scaffold: change did not apply" >&2; exit 1; }
git commit -qam "feat(counter): dismiss a shown fact"

perl -0pi -e 's/(    case factDismissButtonTapped\n)/    \/\/ Added for the dismiss button in the fact banner.\n$1/' "$core"
git add "$core"
