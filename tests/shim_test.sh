#!/usr/bin/env bash
# Regression: a stale cached swiftgate binary after gate/ source changes would run old rules
# silently; an uncached rebuild on every call would blow the <1s hook budget.
set -euo pipefail

repo_src="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/repo"
cp -R "$repo_src/bin" "$work/repo/"
# .build can run into the hundreds of MB; rsync leaves it behind instead of copying it and
# throwing it away.
rsync -a --exclude .build "$repo_src/gate/" "$work/repo/gate/"
export SWIFTGATE_CACHE_DIR="$work/cache"
export SWIFTGATE_BUILD_CONFIG=debug
shim="$work/repo/bin/swiftgate"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Claude Code runs hooks in the session's project directory.
mkdir -p "$work/project/.git" "$work/elsewhere/.git"
touch "$work/project/.swiftgate.toml"

wait_for_background_build() {
  for _ in $(seq 1 600); do
    ls "$SWIFTGATE_CACHE_DIR"/building-* >/dev/null 2>&1 || return 0
    sleep 1
  done
  return 1
}

# A hook on a cold cache must answer at once and build in the background. Each sample resets
# $SWIFTGATE_CACHE_DIR to empty so every repeat measures the same cold state, not the warm path
# after sample 1 — but a cold sample also pays for a real background debug build before the next
# reset can start clean, so this uses fewer, coarser samples than the other budgets (seconds of
# real work per sample, not milliseconds).
cold_samples=()
for i in 1 2 3; do
  rm -rf "$SWIFTGATE_CACHE_DIR"
  hook_start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  hook_out="$(cd "$work/project" && echo '{}' | "$shim" hook stop)" ||
    fail "cold hook $i exited non-zero"
  start_out="$(cd "$work/project" && echo '{}' | "$shim" hook session-start)" ||
    fail "cold session-start $i exited non-zero"
  hook_end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  cold_samples+=("$(perl -e "printf '%d', ($hook_end - $hook_start) * 1000")")
  [ -z "$hook_out" ] || fail "cold stop hook $i printed '$hook_out'"
  # The model must learn from session context that the gates are not enforcing yet.
  printf '%s' "$start_out" | python3 -c '
import json, sys
output = json.load(sys.stdin)["hookSpecificOutput"]
assert output["hookEventName"] == "SessionStart", output
context = output["additionalContext"]
assert "warming up" in context and "not enforced" in context, context
' || fail "cold session-start $i did not inject warm-up context: '$start_out'"
  # Outside a swiftgate project every hook stays silent, cold or not — including mid-build.
  other_out="$(cd "$work/elsewhere" && echo '{}' | "$shim" hook session-start)" ||
    fail "cold session-start outside a project exited non-zero on sample $i"
  [ -z "$other_out" ] || fail "cold session-start outside a project said '$other_out' on sample $i"
  wait_for_background_build || fail "background build $i did not finish"
done
hook_ms="$(printf '%s\n' "${cold_samples[@]}" | sort -n | head -1)"
[ "$hook_ms" -lt 2000 ] ||
  fail "cold hooks took ${cold_samples[*]}ms, fastest ${hook_ms}ms, budget 2000ms"

out1="$("$shim" --version 2>"$work/err1")"
[ "$out1" = "0.1.0" ] || fail "first run printed '$out1': $(cat "$SWIFTGATE_CACHE_DIR"/build-*.log)"
[ ! -s "$work/err1" ] || fail "the background build did not populate the cache: $(cat "$work/err1")"

# The cached path is idempotent (no rebuild, no state change) once warm, so load can only ever
# add time to a sample and never subtract it: the fastest of several samples is the noise-
# resistant read of the shim's real cached-run cost, and a real regression still slows every one.
samples=()
for i in 1 2 3 4 5; do
  start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  out2="$("$shim" --version 2>"$work/err2")"
  end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  [ "$out2" = "0.1.0" ] || fail "cached run $i printed '$out2'"
  [ ! -s "$work/err2" ] || fail "cached run $i wrote to stderr: $(cat "$work/err2")"
  samples+=("$(perl -e "printf '%d', ($end - $start) * 1000")")
done
elapsed="$(printf '%s\n' "${samples[@]}" | sort -n | head -1)"
[ "$elapsed" -lt 1000 ] || fail "cached runs took ${samples[*]}ms, fastest ${elapsed}ms, budget 1000ms"

ln -s "$shim" "$work/linked-swiftgate"
"$work/linked-swiftgate" --version >/dev/null 2>"$work/err3" || fail "symlinked shim failed"
[ ! -s "$work/err3" ] || fail "symlinked shim rebuilt"

echo "// changed" >> "$work/repo/gate/Sources/SwiftGateDomain/SwiftGateDomain.swift"
"$shim" --version >/dev/null 2>"$work/err4"
grep -q "building swiftgate" "$work/err4" || fail "source change did not trigger rebuild"

echo "shim_test: PASS (cached run samples: ${samples[*]}ms, fastest ${elapsed}ms)"
