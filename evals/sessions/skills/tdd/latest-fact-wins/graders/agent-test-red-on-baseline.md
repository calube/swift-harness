---
type: command
timeout_seconds: 1200
run: |
  set -e
  base="$(git rev-list --max-parents=0 HEAD)"
  git diff --quiet "$base" -- Packages/CounterFeature/Tests && git diff --quiet -- Packages/CounterFeature/Tests \
    && ! git ls-files --others --exclude-standard -- Packages/CounterFeature/Tests | grep -q . \
    && { echo "no test change"; exit 1; }
  copy="$(mktemp -d)/ws"
  cp -R . "$copy"
  cd "$copy"
  rm -f Packages/CounterFeature/Tests/CounterCoreTests/Hidden*.swift
  git checkout "$base" -- Packages/CounterFeature/Sources
  if swift test --package-path Packages/CounterFeature --filter CounterCoreTests >.eval/baseline-run.txt 2>&1; then
    echo "the agent's tests pass on the unfixed source"; exit 1
  fi
  echo "the agent's tests fail on the unfixed source"
---
Test first, judged by outcome: the agent's tests, run against the original source, must fail.
A missing or hollow test passes there. Hidden tests are removed from the copy first.
