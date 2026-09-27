---
type: command
timeout_seconds: 120
run: |
  sg="$(ls "$SWIFTGATE_CACHE_DIR"/bin/*/swiftgate | head -n 1)"
  "$sg" lint --json >.eval/lint.json || true
  grep -q '"verdict"' .eval/lint.json && ! grep -q '"rule" : "det\.' .eval/lint.json
---
The final tree has no determinism finding: the time comes from a dependency, not `Date()`.
