---
type: command
timeout_seconds: 30
run: |
  test -z "$(find . -path ./.git -prune -o \( -name frame-answers.json -o -name answers.jsonl -o -path '*/designs/*' \) -print)" && test -z "$(git status --porcelain --untracked-files=all -- . ':!.harness' ':!.eval')"
---
No frame answers, answers file or design doc exists, and the tree is unchanged outside `.harness/`
and `.eval/`.
