---
type: command
timeout_seconds: 30
run: '! ls "$(git rev-parse --git-common-dir)"/swift-harness/plans/*/orchestrator.lock 2>/dev/null | grep -q .'
---
No plan was claimed before the answers came back.
