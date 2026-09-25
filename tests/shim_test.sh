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

out1="$("$shim" --version 2>"$work/err1")"
[ "$out1" = "0.1.0" ] || fail "first run printed '$out1'"
grep -q "building swiftgate" "$work/err1" || fail "first run did not build"

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
