#!/usr/bin/env bash
# Regression: a stale cached swiftgate binary after gate/ source changes would run old rules
# silently; an uncached rebuild on every call would blow the <1s hook budget.
set -euo pipefail

# Every process this test starts, the shims' detached builds included, joins one process group
# that the test leads, so it can reap them all however it ends. A caller without job control
# would otherwise put the test in its own group.
if [ "$(ps -o pgid= -p $$ | tr -d ' ')" != "$$" ] && [ -z "${SHIM_TEST_REGROUPED:-}" ]; then
  SHIM_TEST_REGROUPED=1 exec perl -e 'setpgrp(0, 0); exec @ARGV or die "exec: $!\n"' bash "$0" "$@"
fi

repo_src="$(cd "$(dirname "$0")/.." && pwd -P)"
# The shim resolves its own directory with `pwd -P`, so its build names the physical path
# (/private/var on macOS, where mktemp answers /var). Taking that spelling here is what lets every
# path pattern below reach the build.
work="$(cd "$(mktemp -d)" && pwd -P)"
# $work is a fresh, unique mktemp directory, so anything matched by its path below can only ever
# be this run's own processes — never a process outside this test.

# Kills every other member of this test's process group and every process naming $work (a
# compiler job runs in a group of its own), TERM first, then KILL. Runs from the test itself or
# from its watchdog, which passes its own pid, so both are spared. The group is only this test's
# once it leads it; a watchdog whose test has died still finds the group under the test's pid.
reap() {
  local spared="${1:-$$}" signal member
  for signal in TERM KILL; do
    if [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" = "$$" ] || ! kill -0 $$ 2>/dev/null; then
      for member in $(ps -axo pid=,pgid= | awk -v group=$$ -v spared="$spared" \
        '$2 == group && $1 != group && $1 != spared { print $1 }'); do
        kill -"$signal" "$member" 2>/dev/null || true
      done
    fi
    pkill -"$signal" -f "$work/" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do
      pgrep -f "$work/" >/dev/null 2>&1 || return 0
      sleep 0.2
    done
  done
  return 1
}

deadline_note="$work.deadline"
cleanup() {
  local status="$exiting_with"
  trap - EXIT
  kill "$watchdog" 2>/dev/null || true
  reap || true
  rm -rf "$work"
  if [ -f "$deadline_note" ]; then
    echo "FAIL: shim_test passed its ${SHIM_TEST_DEADLINE_SECONDS:-540}s deadline and was stopped" >&2
    rm -f "$deadline_note"
    status=1
  fi
  # A bounded look for anything this run started that is still alive once it has ended.
  local stray=""
  for _ in $(seq 1 25); do
    stray="$(pgrep -fl "$work/" 2>/dev/null || true)"
    [ -n "$stray" ] || break
    sleep 0.2
  done
  if [ -n "$stray" ]; then
    echo "FAIL: process(es) still running under $work after the test ended: $stray" >&2
    status=1
  fi
  exit "$status"
}
# At the deadline the watchdog's pkill ends the foreground command, so set -e can enter the EXIT
# trap just as the watchdog's TERM lands, even before that trap's first command runs. Bash 3.2 runs
# the TERM trap there, and an exit from it ends the shell with no second EXIT trap. So whichever
# trap runs first runs cleanup itself, and a signal that lands once cleanup has begun is ignored:
# exiting or taking the default action there would cut cleanup short before it reaps or reports
# the deadline. The EXIT trap passes $? as its first word, since any command before reading it
# resets it to 0 and a failing check would exit 0 with its FAIL line on stderr alone.
finish() {
  [ -n "${exiting_with:-}" ] && return 0
  exiting_with="$1"
  cleanup
}
trap 'finish $?' EXIT
trap 'finish 143' TERM
trap 'finish 130' INT
trap 'finish 129' HUP

# The watchdog bounds the run with its own deadline, under the 600s the Swift test harness gives
# it, and reaps what the test started if the test dies without running its EXIT trap (SIGKILL).
# A foreground build would hold off the test's TERM trap until it finished, so the watchdog stops
# everything under $work first.
(
  trap - EXIT TERM INT HUP
  end=$((SECONDS + ${SHIM_TEST_DEADLINE_SECONDS:-540}))
  while kill -0 $$ 2>/dev/null; do
    if [ "$SECONDS" -ge "$end" ]; then
      : >"$deadline_note"
      pkill -TERM -f "$work/" >/dev/null 2>&1 || true
      kill -TERM $$ 2>/dev/null || true
      exit 0
    fi
    sleep 1
  done
  reap "$(exec sh -c 'echo $PPID')" || true
  rm -rf "$work"
) </dev/null >/dev/null 2>&1 &
watchdog=$!
# Killed on exit by design, so the shell has no job to report as terminated.
disown "$watchdog"

mkdir -p "$work/repo/plugin"
cp -R "$repo_src/plugin/bin" "$repo_src/plugin/templates" "$work/repo/plugin/"
# .build can run into the hundreds of MB, and the fixture trees hold two thirds of the package's
# files though no build or shim reads them. This copy is all the work before the first cold hook,
# and its file count is what machine load stretches, so rsync leaves them behind.
rsync -a --exclude .build --exclude /Fixtures --exclude /Tests/Fixtures --exclude '*.profraw' \
  "$repo_src/plugin/gate/" "$work/repo/plugin/gate/"
# An installed plugin's hooks get CLAUDE_PLUGIN_DATA, which outlives the per-version install
# directory, so the build lands there. The user cache is where a contributor checkout builds, and
# it must stay untouched while the data directory is set.
unset SWIFTGATE_CACHE_DIR
export CLAUDE_PLUGIN_DATA="$work/plugin-data"
export XDG_CACHE_HOME="$work/user-cache"
export SWIFTGATE_BUILD_CONFIG=debug
cache="$CLAUDE_PLUGIN_DATA"
shim="$work/repo/plugin/bin/swiftgate"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Claude Code runs hooks in the session's project directory.
mkdir -p "$work/project/.git" "$work/elsewhere/.git"
touch "$work/project/.swiftgate.toml"

wait_for_background_build() {
  for _ in $(seq 1 600); do
    ls "$cache"/building-* >/dev/null 2>&1 || return 0
    sleep 1
  done
  return 1
}

# Kills this run's background build (and every child it spawned) so a killed sample never leaves
# a build running, or contending for CPU, into the next sample. `--package-path` and every source
# file the build touches sit under $work/repo/plugin/gate, so this pattern reaches the swift build
# driver and its compiler children without reaching anything outside this test.
kill_background_build() {
  local pattern="$work/repo/plugin/gate"
  local waited
  for signal in "" "-9"; do
    pkill $signal -f "$pattern" >/dev/null 2>&1 || true
    for waited in $(seq 1 25); do
      pgrep -f "$pattern" >/dev/null 2>&1 || return 0
      sleep 0.2
    done
  done
  return 1
}

# A hook on a cold cache must answer at once and build in the background. Each sample resets
# the data directory to empty so every repeat measures the same cold state, not the warm path
# after sample 1. Letting every cold sample's real background build run to completion would pay
# for 3 debug builds instead of 1 — tripling this test's own contribution to machine load, the
# very thing the other budgets in this file are being made robust to — so samples before the last
# kill their build once measured, instead of waiting for it. If a build can't be killed cleanly,
# this falls back to a single cold sample rather than leave an orphaned build behind.
cold_samples=()
cold_note=""
for i in 1 2 3; do
  rm -rf "$cache"
  hook_start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  hook_out="$(cd "$work/project" && echo '{}' | "$shim" hook stop)" ||
    fail "cold hook $i exited non-zero"
  # Blocking on the build it starts is what a cold hook must never do, and that build takes most
  # of a minute even on an idle machine. So the hook passes when it returns while the build still
  # runs: its lock held and no binary landed. Wall-clock time can't judge this, since machine load
  # stretches a hook that never waited past any fixed budget.
  if ls "$cache"/bin/*/swiftgate >/dev/null 2>&1; then
    fail "cold stop hook $i returned only after the build it started landed its binary: a cold hook blocked on its build"
  fi
  ls -d "$cache"/building-* >/dev/null 2>&1 ||
    fail "cold stop hook $i returned with no build running under $cache: $(cat "$cache"/build-*.log 2>/dev/null)"
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

  if [ "$i" -lt 3 ]; then
    if kill_background_build; then
      continue
    fi
    cold_note=" (sample $i's background build could not be killed cleanly, so this fell back to 1 cold sample)"
    break
  fi
done
# Whichever sample was last — the real one on a clean run, or the one that could not be killed on
# a fallback — its build is still running (or just finished) and must be let finish, since every
# check below expects a populated cache.
wait_for_background_build || fail "background build did not finish"
hook_ms="$(printf '%s\n' "${cold_samples[@]}" | sort -n | head -1)"

out1="$("$shim" --version 2>"$work/err1")"
[ "$out1" = "0.1.0" ] || fail "first run printed '$out1': $(cat "$cache"/build-*.log)"
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

built=("$cache"/bin/*/swiftgate)
[ -x "${built[0]}" ] || fail "no swiftgate binary under the plugin data directory $cache/bin"
[ ! -e "$XDG_CACHE_HOME/swift-harness" ] ||
  fail "the shim wrote to the user cache while CLAUDE_PLUGIN_DATA was set"

ln -s "$shim" "$work/linked-swiftgate"
"$work/linked-swiftgate" --version >/dev/null 2>"$work/err3" || fail "symlinked shim failed"
[ ! -s "$work/err3" ] || fail "symlinked shim rebuilt"

# Hooks can run under a different locale than the build that warmed the cache; the same sources
# must still hash to the cached binary, or every hook goes quiet for a cold rebuild. Deleting the
# stamp forces a rehash. A hook on a miss builds in the background without writing a stamp, so a
# missing stamp or a build lock is the miss.
cached_hash="$(ls "$cache/bin")"
[ "$(printf '%s\n' "$cached_hash" | wc -l | tr -d ' ')" = 1 ] ||
  fail "expected one cached binary, found: $cached_hash"
for locale in C en_US.UTF-8; do
  rm -f "$cache"/stamps/*
  payload="{\"session_id\":\"shim-test\",\"cwd\":\"$work/elsewhere\",\"hook_event_name\":\"Stop\"}"
  (cd "$work/elsewhere" && echo "$payload" | LC_ALL="$locale" "$shim" hook stop >/dev/null) ||
    fail "hook under LC_ALL=$locale exited non-zero"
  if ls "$cache"/building-* >/dev/null 2>&1; then
    kill_background_build || true
    fail "LC_ALL=$locale missed the cached binary $cached_hash and started a rebuild"
  fi
  stamped="$(cat "$cache"/stamps/* 2>/dev/null || true)"
  [ "$stamped" = "$cached_hash" ] ||
    fail "LC_ALL=$locale hashed the same sources to '$stamped', cached binary is $cached_hash"
done

# While a hook's own binary is missing (sources changed, rebuild pending) it runs the last binary
# this gate built instead of going quiet: stale rules still enforce. The real binary is moved under
# a stale hash, so the current hash has none.
stale=0000000000000000
mkdir -p "$cache/bin/$stale"
mv "$cache/bin/$cached_hash/swiftgate" "$cache/bin/$stale/swiftgate"
deny_payload="{\"session_id\":\"shim-test\",\"cwd\":\"$work/project\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"xcodebuild build\"}}"
stop_rebuild() {
  for _ in $(seq 1 25); do
    pkill -9 -f "$work/repo/plugin/" >/dev/null 2>&1 || true
    sleep 0.2
    pgrep -f "$work/repo/plugin/" >/dev/null 2>&1 || break
  done
  rmdir "$cache/building-$cached_hash" 2>/dev/null || true
}
# Each hook below starts a rebuild that runs a stand-in swift holding the build open, so a hook is
# judged by whether it returned while its rebuild still ran, never by wall-clock time. A real
# rebuild of unchanged sources can land in a second or two, before a slowed hook returns. The hold
# outlasts the PreToolUse hook timeout: Claude Code would kill a hook that waited on its rebuild
# before the hold ended, and here that hook returns only after the stand-in marks the hold's end.
pre_tool_use_timeout="$(python3 -c '
import json, sys
entries = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
print(max(hook["timeout"] for entry in entries for hook in entry["hooks"]))
' "$repo_src/plugin/hooks/hooks.json")" || fail "could not read the PreToolUse hook timeout from hooks.json"
held_bin="$work/held-bin"
rebuild_hold_ended="$work/rebuild-hold.ended"
mkdir -p "$held_bin"
cat >"$held_bin/swift" <<EOF
#!/usr/bin/perl
sleep $((pre_tool_use_timeout + 5));
open my \$marker, '>', '$rebuild_hold_ended' or die "$rebuild_hold_ended: \$!\n";
exit 1;
EOF
chmod +x "$held_bin/swift"
# Called right after a hook returns, before its rebuild is stopped.
rebuild_still_held() {
  [ ! -e "$rebuild_hold_ended" ] || fail "$1: the hook returned only after its rebuild ended: it waited on the rebuild"
  [ -d "$cache/building-$cached_hash" ] || fail "$1: a hook with no binary for its hash started no rebuild"
  [ ! -e "$cache/bin/$cached_hash/swiftgate" ] || fail "$1: a binary for the current hash landed while its rebuild was held"
}
# A loaded machine can hold a hook back for seconds: the previous binary's first launch from its
# new path waits on system code-signing checks that load starves. A stand-in bash holds this hook's
# start back the same way, so nothing below may judge the hook by how long it took.
stretched_bin="$work/stretched-bin"
mkdir -p "$stretched_bin"
cat >"$stretched_bin/bash" <<'EOF'
#!/usr/bin/perl
select undef, undef, undef, 3;
exec '/bin/bash', @ARGV or die "exec: $!\n";
EOF
chmod +x "$stretched_bin/bash"
stale_out="$(cd "$work/project" && echo "$deny_payload" | PATH="$stretched_bin:$held_bin:$PATH" "$shim" hook pre-tool-use)" ||
  fail "hook during a rebuild exited non-zero"
rebuild_still_held "a hook during a rebuild"
stop_rebuild
case "$stale_out" in
  *'"permissionDecision":"deny"'*) ;;
  *) fail "during a rebuild the hook did not enforce with the last good binary: '$stale_out'" ;;
esac
# The gate's own last build wins over a newer binary another checkout left in a shared cache; with
# no record of it, the newest cached binary runs. A decoy tells which one ran.
decoy=ffffffffffffffff
mkdir -p "$cache/bin/$decoy"
printf '#!/bin/sh\necho "decoy ${SWIFTGATE_SOURCE_HASH:-unset}"\n' >"$cache/bin/$decoy/swiftgate"
chmod +x "$cache/bin/$decoy/swiftgate"
touch "$cache/bin/$decoy/swiftgate"
pointer=("$cache"/last-good/*)
[ "$(cat "${pointer[0]}" 2>/dev/null)" = "$cached_hash" ] ||
  fail "the build did not record its hash as the last good binary"
printf '%s\n' "$stale" >"${pointer[0]}"
recorded_out="$(cd "$work/project" && echo "$deny_payload" | PATH="$held_bin:$PATH" "$shim" hook pre-tool-use)" ||
  fail "hook with a last-good record exited non-zero"
rebuild_still_held "a hook with a last-good record"
stop_rebuild
case "$recorded_out" in
  *'"permissionDecision":"deny"'*) ;;
  *) fail "the recorded last good binary did not run ahead of a newer one: '$recorded_out'" ;;
esac
/bin/rm -f "${pointer[0]}"
newest_out="$(cd "$work/project" && echo "$deny_payload" | PATH="$held_bin:$PATH" "$shim" hook pre-tool-use)" ||
  fail "hook with no last-good record exited non-zero"
rebuild_still_held "a hook with no last-good record"
stop_rebuild
# The fallback binary must name its own hash in its events, never the hash still being built.
[ "$newest_out" = "decoy $decoy" ] ||
  fail "with no last-good record the newest cached binary did not run, or did not see its own hash: '$newest_out'"
/bin/rm -rf "$cache/bin/$decoy" "$cache/bin/$cached_hash"
mv "$cache/bin/$stale" "$cache/bin/$cached_hash"
printf '%s\n' "$cached_hash" >"${pointer[0]}"
"$shim" --version >/dev/null 2>"$work/err-restore" || fail "the restored cache did not run"
[ ! -s "$work/err-restore" ] || fail "the restored cache rebuilt: $(cat "$work/err-restore")"

# The binary the shim execs reads the hash it was cached under from the environment, to name
# itself in every event it writes. A stand-in under the current hash prints what it was handed.
mv "$cache/bin/$cached_hash/swiftgate" "$work/real-swiftgate"
printf '#!/bin/sh\necho "${SWIFTGATE_SOURCE_HASH:-unset}"\n' >"$cache/bin/$cached_hash/swiftgate"
chmod +x "$cache/bin/$cached_hash/swiftgate"
seen_hash="$(SWIFTGATE_SOURCE_HASH=stale "$shim" --version)" || fail "the hash stand-in did not run"
mv -f "$work/real-swiftgate" "$cache/bin/$cached_hash/swiftgate"
[ "$seen_hash" = "$cached_hash" ] ||
  fail "the exec'd binary saw SWIFTGATE_SOURCE_HASH '$seen_hash', not its hash $cached_hash"

# A session `swiftgate run` starts with --plugin-dir gives the plugin's hooks a data directory of
# their own. When it holds only an older binary but the user cache, which the run warmed, holds
# this exact hash, a hook must run the exact one, never the older one while a rebuild runs. The
# held stand-in swift keeps any rebuild from landing, so only the reuse can supply the binary.
inline="$work/inline-data"
user_cache="$XDG_CACHE_HOME/swift-harness"
mkdir -p "$user_cache/bin/$cached_hash" "$inline/bin/$decoy" "$inline/last-good"
/bin/cp -f "$cache/bin/$cached_hash/swiftgate" "$user_cache/bin/$cached_hash/swiftgate"
printf '#!/bin/sh\necho decoy\n' >"$inline/bin/$decoy/swiftgate"
chmod +x "$inline/bin/$decoy/swiftgate"
pointer_name="$(basename "${pointer[0]}")"
printf '%s\n' "$decoy" >"$inline/last-good/$pointer_name"
inline_out="$(cd "$work/project" && echo "$deny_payload" |
  CLAUDE_PLUGIN_DATA="$inline" PATH="$held_bin:$PATH" "$shim" hook pre-tool-use)" ||
  fail "a plugin hook with its own data directory exited non-zero"
if [ -d "$inline/building-$cached_hash" ]; then
  stop_rebuild
  rmdir "$inline/building-$cached_hash" 2>/dev/null || true
  fail "a plugin hook started a rebuild though the user cache held its exact hash $cached_hash"
fi
case "$inline_out" in
  *'"permissionDecision":"deny"'*) ;;
  *) fail "a plugin hook ran a binary of another hash, not the exact one in the user cache: '$inline_out'" ;;
esac
[ -x "$inline/bin/$cached_hash/swiftgate" ] ||
  fail "the exact-hash binary was not reused into the plugin's data directory"
[ "$(cat "$inline/last-good/$pointer_name")" = "$cached_hash" ] ||
  fail "the reused binary was not recorded as the plugin data directory's last good binary"
CLAUDE_PLUGIN_DATA="$inline" "$shim" --version >/dev/null 2>"$work/err-inline" ||
  fail "the reused binary did not run"
[ ! -s "$work/err-inline" ] || fail "the reused binary rebuilt: $(cat "$work/err-inline")"
/bin/rm -rf "$inline" "$user_cache"

# Bootstrap links ~/.local/bin/swiftgate, which git hooks call, to the shim it ran through: the
# plugin's own. A link left at a checkout-root bin/swiftgate from before the plugin moved into
# plugin/ is repointed, whether its old target still exists or not.
for old_exists in yes no; do
  app="$work/app-$old_exists"
  home="$work/home-$old_exists"
  mkdir -p "$app/Packages/Core" "$home/.local/bin" "$work/old-checkout/bin"
  echo '// swift-tools-version: 6.2' >"$app/Packages/Core/Package.swift"
  git -C "$app" init -q
  if [ "$old_exists" = yes ]; then
    printf '#!/bin/sh\n' >"$work/old-checkout/bin/swiftgate"
    chmod +x "$work/old-checkout/bin/swiftgate"
  else
    rm -f "$work/old-checkout/bin/swiftgate"
  fi
  ln -sf "$work/old-checkout/bin/swiftgate" "$home/.local/bin/swiftgate"
  (cd "$app" && HOME="$home" "$shim" bootstrap --apply >"$work/bootstrap-$old_exists.log" 2>&1) ||
    fail "bootstrap --apply failed (old shim exists: $old_exists): $(cat "$work/bootstrap-$old_exists.log")"
  linked="$(readlink "$home/.local/bin/swiftgate")"
  expected="$(cd "$work/repo/plugin/bin" && pwd -P)/swiftgate"
  [ "$linked" = "$expected" ] ||
    fail "~/.local/bin/swiftgate points at '$linked', not the plugin shim '$expected' (old shim exists: $old_exists)"
done

echo "// changed" >> "$work/repo/plugin/gate/Sources/SwiftGateDomain/SwiftGateDomain.swift"
"$shim" --version >/dev/null 2>"$work/err4"
grep -q "building swiftgate" "$work/err4" || fail "source change did not trigger rebuild"

# Without a plugin data directory (a contributor checkout, or the ~/.local/bin link from a
# terminal) the shim falls back to the user cache. A cold hook only starts the build, so this
# costs no compile: the build it started is killed once its lock shows where it went.
(cd "$work/project" && echo '{}' | env -u CLAUDE_PLUGIN_DATA "$shim" hook stop) ||
  fail "cold hook without CLAUDE_PLUGIN_DATA exited non-zero"
# The lock is taken before the hook returns; the log only once the detached build starts.
ls -d "$XDG_CACHE_HOME"/swift-harness/building-* >/dev/null 2>&1 ||
  fail "without CLAUDE_PLUGIN_DATA the shim did not build into the user cache"
# The hook detached a subshell that runs the shim, which may not have reached `swift build` yet,
# so the subshell itself is killed too: every process of it names this run's plugin copy.
for _ in $(seq 1 25); do
  pkill -9 -f "$work/repo/plugin/" >/dev/null 2>&1 || true
  sleep 0.2
  pgrep -f "$work/repo/plugin/" >/dev/null 2>&1 || break
done

# A cold hook (no binary, no previous binary) is the only session-start a fresh install or a
# wiped cache ever sees. The plan/design/build/ship skills read the session id only from the
# rendered "Session id: " line and refuse to claim work without it, so this line has to reach the
# model even while the real binary is still building.
sid_cache="$work/sid-cache"

sid_out="$(
  cd "$work/project" &&
    printf '%s' '{"session_id":"abc-123","cwd":"'"$work/project"'","hook_event_name":"SessionStart"}' |
    CLAUDE_PLUGIN_DATA="$sid_cache" "$shim" hook session-start
)" || fail "cold session-start with a session id exited non-zero"
kill_background_build || true
printf '%s\n' "$sid_out" | python3 -m json.tool >/dev/null ||
  fail "cold session-start with a session id was not valid JSON: '$sid_out'"
case "$sid_out" in
  *"Session id: abc-123"*) ;;
  *) fail "cold session-start did not surface the stdin session id: '$sid_out'" ;;
esac
rm -rf "$sid_cache"

# An id outside the safe character set is dropped rather than trusted into the printed JSON.
unsafe_out="$(
  cd "$work/project" &&
    printf '%s' '{"session_id":"abc 123\"; touch evil","cwd":"'"$work/project"'"}' |
    CLAUDE_PLUGIN_DATA="$sid_cache" "$shim" hook session-start
)" || fail "cold session-start with an unsafe session id exited non-zero"
kill_background_build || true
printf '%s\n' "$unsafe_out" | python3 -m json.tool >/dev/null ||
  fail "cold session-start with an unsafe session id was not valid JSON: '$unsafe_out'"
case "$unsafe_out" in
  *"Session id:"*) fail "cold session-start printed an unsafe session id: '$unsafe_out'" ;;
esac
rm -rf "$sid_cache"

# Empty or absent stdin (a tty, or a hook invoked with none) must not block or crash the hook.
nostdin_out="$(cd "$work/project" && CLAUDE_PLUGIN_DATA="$sid_cache" "$shim" hook session-start </dev/null)" ||
  fail "cold session-start with no stdin exited non-zero"
kill_background_build || true
printf '%s\n' "$nostdin_out" | python3 -m json.tool >/dev/null ||
  fail "cold session-start with no stdin was not valid JSON: '$nostdin_out'"
case "$nostdin_out" in
  *"Session id:"*) fail "cold session-start with no stdin printed a session id: '$nostdin_out'" ;;
esac
rm -rf "$sid_cache"
# Each case above already waited out its own background build; a build that spawned late (the
# swift build driver itself takes a moment to fork its child) gets one more, broader pass here.
for _ in $(seq 1 50); do
  pkill -9 -f "$work/repo/plugin/" >/dev/null 2>&1 || true
  sleep 0.2
  pgrep -f "$work/repo/plugin/gate" >/dev/null 2>&1 || break
done

# Gates in different worktrees build in scratch paths of their own, so neither queues on the
# other's SwiftPM lock. A stand-in swift models that lock: each build announces itself, takes a
# lock in its scratch path (noting once if it had to wait), and holds it until both builds have
# announced themselves, so the two always overlap. Its binary embeds whatever hash the shim asked
# to link in, or a wrong one on request.
standin_bin="$work/standin-bin"
standin_log="$work/standin.log"
mkdir -p "$standin_bin"
cat >"$standin_bin/swift" <<'EOF'
#!/bin/bash
scratch="" config=debug hash_file="" show=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-path) scratch="$2"; shift ;;
    -c) config="$2"; shift ;;
    --show-bin-path) show=1 ;;
    */source-hash-*) hash_file="$1" ;;
  esac
  shift
done
if [ -n "$show" ]; then echo "$scratch/$config"; exit 0; fi
mkdir -p "$scratch/$config"
echo "arrived $scratch" >>"$STANDIN_LOG"
noted=""
until mkdir "$scratch/.standin-lock" 2>/dev/null; do
  [ -n "$noted" ] || { echo "waited $scratch" >>"$STANDIN_LOG"; noted=1; }
  sleep 0.1
done
echo "built $scratch" >>"$STANDIN_LOG"
for _ in $(seq 1 600); do
  [ "$(grep -c '^arrived ' "$STANDIN_LOG")" -ge "${STANDIN_PEERS:-1}" ] && break
  sleep 0.1
done
if [ -n "${STANDIN_WRONG_HASH:-}" ]; then
  marker="swiftgate-source-hash=$STANDIN_WRONG_HASH;"
else
  marker="$(cat "$hash_file" 2>/dev/null)"
fi
printf '#!/bin/sh\n# %s\necho standin-binary\n' "$marker" >"$scratch/$config/swiftgate"
chmod +x "$scratch/$config/swiftgate"
rmdir "$scratch/.standin-lock"
EOF
chmod +x "$standin_bin/swift"
wt_cache="$work/worktree-cache"
for wt in wt1 wt2; do
  mkdir -p "$work/$wt/plugin/gate"
  /bin/cp -R "$work/repo/plugin/bin" "$work/$wt/plugin/"
  rsync -a --exclude .build "$work/repo/plugin/gate/" "$work/$wt/plugin/gate/"
done
standin() {
  (cd "$work/elsewhere" && CLAUDE_PLUGIN_DATA="$wt_cache" STANDIN_LOG="$standin_log" \
    PATH="$standin_bin:$PATH" "$@")
}
: >"$standin_log"
STANDIN_PEERS=2 standin "$work/wt1/plugin/bin/swiftgate" --version >"$work/wt1.out" 2>"$work/wt1.err" &
wt1_build=$!
STANDIN_PEERS=2 standin "$work/wt2/plugin/bin/swiftgate" --version >"$work/wt2.out" 2>"$work/wt2.err" &
wt2_build=$!
wt1_status=0 wt2_status=0
wait "$wt1_build" || wt1_status=$?
wait "$wt2_build" || wt2_status=$?
[ "$wt1_status" = 0 ] && [ "$wt2_status" = 0 ] ||
  fail "concurrent worktree builds exited $wt1_status and $wt2_status: $(cat "$work/wt1.err" "$work/wt2.err")"
! grep -q '^waited ' "$standin_log" ||
  fail "one worktree's build waited on another's scratch lock: $(cat "$standin_log")"
scratches="$(sed -n 's/^built //p' "$standin_log" | sort -u)"
[ "$(printf '%s\n' "$scratches" | wc -l | tr -d ' ')" = 2 ] ||
  fail "two worktrees did not build in two scratch paths: $(cat "$standin_log")"
for wt in wt1 wt2; do
  [ "$(cat "$work/$wt.out")" = standin-binary ] || fail "$wt did not run its build: '$(cat "$work/$wt.out")'"
  owned=""
  for scratch in $scratches; do
    [ "$(cat "$(dirname "$scratch")/gate-path" 2>/dev/null)" = "$work/$wt/plugin/gate" ] && owned="$scratch"
  done
  [ -n "$owned" ] || fail "no scratch path records $wt's gate as its owner: $scratches"
  eval "${wt}_scratch=\$(dirname \"\$owned\")"
done

# A build first drops the scratch of a worktree that is gone, with its stamp, and keeps a live
# one's. A scratch path that records no gate goes once nothing in it changed for a day. The
# cached path never prunes: a dead worktree's scratch outlives a run that builds nothing.
/bin/rm -rf "$work/wt2"
wt2_key="$(basename "$wt2_scratch")"
mkdir -p "$wt_cache/stamps" "$wt_cache/build/debug" "$wt_cache/build/release"
: >"$wt_cache/stamps/$wt2_key"
touch -t 200001010000 "$wt_cache/build/debug"
standin "$work/wt1/plugin/bin/swiftgate" --version >/dev/null 2>"$work/wt1.err" ||
  fail "cached run in a live worktree failed: $(cat "$work/wt1.err")"
[ -d "$wt2_scratch" ] || fail "a run that built nothing pruned a scratch path"
echo "// changed" >>"$work/wt1/plugin/gate/Sources/SwiftGateDomain/SwiftGateDomain.swift"
standin "$work/wt1/plugin/bin/swiftgate" --version >/dev/null 2>"$work/wt1.err" ||
  fail "rebuild in a live worktree failed: $(cat "$work/wt1.err")"
[ ! -e "$wt2_scratch" ] || fail "a build kept the scratch path of a removed worktree: $wt2_scratch"
[ ! -e "$wt_cache/stamps/$wt2_key" ] || fail "a build kept the stamp of a removed worktree"
[ -d "$wt1_scratch" ] || fail "a build pruned the scratch path of a live worktree: $wt1_scratch"
[ ! -e "$wt_cache/build/debug" ] || fail "a build kept an ownerless scratch path unchanged for a day"
[ -d "$wt_cache/build/release" ] || fail "a build pruned an ownerless scratch path changed today"

# A build that leaves a binary of other sources (SwiftPM can reuse an earlier tree's build plan in
# a shared scratch path) is never filed under this hash or run, even after the one retry.
echo "// changed again" >>"$work/wt1/plugin/gate/Sources/SwiftGateDomain/SwiftGateDomain.swift"
: >"$standin_log"
mismatch_status=0
STANDIN_WRONG_HASH=0000000000000000 standin "$work/wt1/plugin/bin/swiftgate" --version \
  >"$work/mismatch.out" 2>"$work/mismatch.err" || mismatch_status=$?
mismatch_hash="$(sed -n 's/.*building swiftgate (debug, \([0-9a-f]*\)).*/\1/p' "$work/mismatch.err" | head -n 1)"
[ -n "$mismatch_hash" ] || fail "the shim did not build for the changed sources: $(cat "$work/mismatch.err")"
! grep -q standin-binary "$work/mismatch.out" ||
  fail "the shim ran a binary that does not embed its source hash $mismatch_hash"
[ ! -e "$wt_cache/bin/$mismatch_hash/swiftgate" ] ||
  fail "the shim cached a binary that does not embed its source hash $mismatch_hash"
[ "$mismatch_status" != 0 ] || fail "the shim exited 0 with no binary of its sources"
[ "$(grep -c '^built ' "$standin_log")" = 2 ] ||
  fail "a mismatched build was not retried exactly once: $(cat "$standin_log")"
# A binary already filed under this hash without the check (an older shim cached it) is checked
# before it runs, and replaced by a build when it embeds another hash.
mkdir -p "$wt_cache/bin/$mismatch_hash"
printf '#!/bin/sh\necho unchecked-binary\n' >"$wt_cache/bin/$mismatch_hash/swiftgate"
chmod +x "$wt_cache/bin/$mismatch_hash/swiftgate"
unchecked_out="$(standin "$work/wt1/plugin/bin/swiftgate" --version 2>"$work/unchecked.err")" ||
  fail "the shim failed to replace an unchecked binary: $(cat "$work/unchecked.err")"
[ "$unchecked_out" = standin-binary ] ||
  fail "the shim ran a cached binary that does not embed its source hash: '$unchecked_out'"

# Every background build this test started was either killed and reaped, or let finish — none
# should still be running.
stray="$(pgrep -fl "$work" 2>/dev/null || true)"
[ -z "$stray" ] || fail "stray process(es) still running under \$work: $stray"

echo "shim_test: PASS (cold samples: ${cold_samples[*]}ms, fastest ${hook_ms}ms${cold_note}; cached run samples: ${samples[*]}ms, fastest ${elapsed}ms)"
