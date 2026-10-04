#!/usr/bin/env bash
# Re-captures every `agent-device` fixture in this directory and the pinned tool's step schemas.
# Usage: capture.sh <path to a simulator build of SampleApp.app>
# Every call targets a throwaway device this script creates, boots and deletes, so a device
# another session or tool is using is never touched.
set -uo pipefail

app="$(cd "$1" && pwd -P)"
here="$(cd "$(dirname "$0")" && pwd -P)"
out="$here"
work="$(cd "$(mktemp -d)" && pwd -P)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
bundle="com.example.SampleApp"
session="swiftgate-capture"
absent="No such text anywhere"

udid="$(xcrun simctl create "agent-device-capture-$$" "$type" "$runtime")"
cleanup() {
  agent-device close --udid "$udid" --session "$session" --json >/dev/null 2>&1
  xcrun simctl shutdown "$udid" >/dev/null 2>&1
  xcrun simctl delete "$udid" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

scrub() {
  sed -e "s#$work#/SCRATCH#g" -e "s#$HOME#/HOME#g" "$1"
}

record() {
  local name="$1"
  shift
  agent-device "$@" >"$work/stdout" 2>"$work/stderr"
  echo "$?" >"$out/$name.status"
  scrub "$work/stdout" >"$out/$name.stdout"
  scrub "$work/stderr" >"$out/$name.stderr"
}

target=(--udid "$udid" --session "$session" --json)

xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"

record version --version
record open open "$bundle" --udid "$udid" --session "$session" \
  --launch-args -harness-scenario --launch-args live --json
# The app process's argv on the host shows whether the launch arguments reached the app.
ps -axo args= | grep "^[^ ]*/Devices/$udid/[^ ]*/SampleApp\.app/SampleApp" \
  | sed -e "s#^[^ ]*/SampleApp.app/SampleApp#SampleApp#" >"$out/open-launch-args.txt"
record snapshot snapshot "${target[@]}"
record screenshot screenshot "$work/step.png" "${target[@]}"
record appstate appstate "${target[@]}"
record session-list session list "${target[@]}"
record wait-text-absent wait text "$absent" 2000 "${target[@]}"
record wait-text-absent-plain wait text "$absent" 2000 --udid "$udid" --session "$session"
record open-device-in-use open "$bundle" --udid "$udid" --session "$session-other" --json
record open-unknown-udid open "$bundle" --udid 00000000-0000-0000-0000-000000000000 \
  --session "$session-unknown" --json

cat >"$work/pass.json" <<'EOF'
[{"command":"wait","input":{"kind":"selector","selector":"id=\"counter.value\"","timeoutMs":5000}},
 {"command":"press","input":{"target":{"kind":"selector","selector":"id=\"counter.increment\""}}},
 {"command":"is","input":{"predicate":"text","selector":"id=\"counter.value\"","value":"1"}},
 {"command":"snapshot","input":{}}]
EOF
cat >"$work/fail.json" <<'EOF'
[{"command":"wait","input":{"kind":"selector","selector":"id=\"counter.value\"","timeoutMs":5000}},
 {"command":"wait","input":{"kind":"text","text":"No such text anywhere","timeoutMs":2000}},
 {"command":"press","input":{"target":{"kind":"selector","selector":"id=\"counter.increment\""}}}]
EOF
cat >"$work/invalid.json" <<'EOF'
[{"command":"wait","input":{"target":{"kind":"selector","selector":"id=\"counter.value\""}}}]
EOF
cat >"$work/record.json" <<EOF
[{"command":"record","input":{"action":"start","path":"$work/batch.mp4"}},
 {"command":"press","input":{"target":{"kind":"selector","selector":"id=\"counter.decrement\""}}},
 {"command":"wait","input":{"kind":"selector","selector":"id=\"counter.value\"","timeoutMs":5000}},
 {"command":"record","input":{"action":"stop"}}]
EOF
record batch-pass batch --steps-file "$work/pass.json" --on-error stop "${target[@]}"
record batch-fail batch --steps-file "$work/fail.json" --on-error stop "${target[@]}"
record batch-invalid batch --steps-file "$work/invalid.json" --on-error stop "${target[@]}"
record batch-record batch --steps-file "$work/record.json" --on-error stop "${target[@]}"

record record-start record start "$work/flow.mp4" "${target[@]}"
agent-device press 'id="counter.increment"' "${target[@]}" >/dev/null 2>&1
record record-stop record stop "${target[@]}"
record contact-sheet record contact-sheet "$work/flow.mp4" --out "$work/flow-sheet.png" --json
record logs-path logs path "${target[@]}"
record network-dump network dump 25 --include headers "${target[@]}"
record trace-start trace start "$work/trace.log" "${target[@]}"
record trace-stop trace stop "$work/trace.log" "${target[@]}"
record close close "${target[@]}"
# `device` refuses `--session`, so the release names the device alone.
record device-release-session-refused device release --stale "${target[@]}"
record device-release-stale device release --stale --udid "$udid" --json

# The MCP server's `tools/list` holds every command's input schema at this version.
version="$(agent-device --version)"
/usr/bin/python3 - "$here/../../../../qa/agent-device-schemas-$version.json" <<'EOF'
import json, subprocess, sys

server = subprocess.Popen(["agent-device", "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          text=True)
def send(message):
    server.stdin.write(json.dumps(message) + "\n")
    server.stdin.flush()
def answer(request_id):
    for line in server.stdout:
        message = json.loads(line)
        if message.get("id") == request_id:
            return message["result"]
    sys.exit("agent-device mcp closed before answering request %d" % request_id)

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                 "clientInfo": {"name": "swiftgate-capture", "version": "1"}}})
initialized = answer(1)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
tools = answer(2)
server.stdin.close()
server.wait()
with open(sys.argv[1], "w") as file:
    json.dump({"serverInfo": initialized["serverInfo"], "tools": tools["tools"]}, file,
              indent=1, sort_keys=True)
    file.write("\n")
EOF
