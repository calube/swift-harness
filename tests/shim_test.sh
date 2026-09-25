#!/usr/bin/env bash
# Regression: a stale cached swiftgate binary after gate/ source changes would run old rules
# silently; an uncached rebuild on every call would blow the <1s hook budget.
set -euo pipefail

repo_src="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/repo"
cp -R "$repo_src/bin" "$repo_src/gate" "$work/repo/"
rm -rf "$work/repo/gate/.build"
export SWIFTGATE_CACHE_DIR="$work/cache"
export SWIFTGATE_BUILD_CONFIG=debug
shim="$work/repo/bin/swiftgate"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Claude Code runs hooks in the session's project directory.
mkdir -p "$work/project/.git" "$work/elsewhere/.git"
touch "$work/project/.swiftgate.toml"

# A hook on a cold cache must answer at once and build in the background.
hook_start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
hook_out="$(cd "$work/project" && echo '{}' | "$shim" hook stop)" || fail "cold hook exited non-zero"
start_out="$(cd "$work/project" && echo '{}' | "$shim" hook session-start)" ||
  fail "cold session-start exited non-zero"
hook_end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
hook_ms=$(perl -e "printf '%d', ($hook_end - $hook_start) * 1000")
[ -z "$hook_out" ] || fail "cold stop hook printed '$hook_out'"
# The model must learn from session context that the gates are not enforcing yet.
printf '%s' "$start_out" | python3 -c '
import json, sys
output = json.load(sys.stdin)["hookSpecificOutput"]
assert output["hookEventName"] == "SessionStart", output
context = output["additionalContext"]
assert "warming up" in context and "not enforced" in context, context
' || fail "cold session-start did not inject warm-up context: '$start_out'"
[ "$hook_ms" -lt 2000 ] || fail "cold hooks took ${hook_ms}ms"
# Outside a swiftgate project every hook stays silent, cold or not.
other_out="$(cd "$work/elsewhere" && echo '{}' | "$shim" hook session-start)" ||
  fail "cold session-start outside a project exited non-zero"
[ -z "$other_out" ] || fail "cold session-start outside a project said '$other_out'"
for _ in $(seq 1 600); do
  ls "$SWIFTGATE_CACHE_DIR"/building-* >/dev/null 2>&1 || break
  sleep 1
done
ls "$SWIFTGATE_CACHE_DIR"/building-* >/dev/null 2>&1 && fail "background build did not finish"

out1="$("$shim" --version 2>"$work/err1")"
[ "$out1" = "0.1.0" ] || fail "first run printed '$out1': $(cat "$SWIFTGATE_CACHE_DIR"/build-*.log)"
[ ! -s "$work/err1" ] || fail "the background build did not populate the cache: $(cat "$work/err1")"

start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
out2="$("$shim" --version 2>"$work/err2")"
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
[ "$out2" = "0.1.0" ] || fail "cached run printed '$out2'"
[ ! -s "$work/err2" ] || fail "cached run wrote to stderr: $(cat "$work/err2")"
elapsed=$(perl -e "printf '%d', ($end - $start) * 1000")
[ "$elapsed" -lt 1000 ] || fail "cached run took ${elapsed}ms"

ln -s "$shim" "$work/linked-swiftgate"
"$work/linked-swiftgate" --version >/dev/null 2>"$work/err3" || fail "symlinked shim failed"
[ ! -s "$work/err3" ] || fail "symlinked shim rebuilt"

echo "// changed" >> "$work/repo/gate/Sources/SwiftGateDomain/SwiftGateDomain.swift"
"$shim" --version >/dev/null 2>"$work/err4"
grep -q "building swiftgate" "$work/err4" || fail "source change did not trigger rebuild"

echo "shim_test: PASS (cached run ${elapsed}ms)"
