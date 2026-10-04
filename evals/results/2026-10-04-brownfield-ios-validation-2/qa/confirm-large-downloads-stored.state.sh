#!/usr/bin/env bash
# req-stored: after the stored flow switches the toggle on, the installed app's
# user defaults hold `true` under Downloads.confirmLargeDownloads.
set -uo pipefail

KEY="Downloads.confirmLargeDownloads"
: "${QA_SIM_UDID:?QA_SIM_UDID is required (run after the stored flow)}"

bundle="${QA_SIM_BUNDLE_ID:-}"
if [[ -z "$bundle" ]]; then
  # Resolve PRODUCT_BUNDLE_IDENTIFIER = $(APP_ID_PREFIX).$(APP_ID_SUFFIX) from the app's xcconfig.
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  cfg="$root/Aidoku/Aidoku.xcconfig"
  prefix="$(sed -nE 's/^[[:space:]]*APP_ID_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$cfg" | head -n1)"
  suffix="$(sed -nE 's/^[[:space:]]*APP_ID_SUFFIX[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$cfg" | head -n1)"
  bundle="$prefix.$suffix"
fi
if [[ -z "$bundle" || "$bundle" == "." ]]; then
  echo "FAIL: could not resolve the app bundle id" >&2
  exit 2
fi

container="$(xcrun simctl get_app_container "$QA_SIM_UDID" "$bundle" data 2>/dev/null)"
if [[ -z "$container" ]]; then
  echo "FAIL: no data container for $bundle on $QA_SIM_UDID" >&2
  exit 2
fi
plist="$container/Library/Preferences/$bundle.plist"

read_value() {
  # Ask the simulator's cfprefsd first so an unflushed write still counts.
  local v
  v="$(xcrun simctl spawn "$QA_SIM_UDID" defaults read "$plist" "$KEY" 2>/dev/null)" && { echo "$v"; return 0; }
  [[ -f "$plist" ]] && /usr/libexec/PlistBuddy -c "Print :$KEY" "$plist" 2>/dev/null
}

value=""
for _ in $(seq 1 10); do
  value="$(read_value || true)"
  [[ "$value" == "1" || "$value" == "true" ]] && break
  sleep 1
done

echo "bundle=$bundle key=$KEY value=${value:-<unset>}"
if [[ "$value" == "1" || "$value" == "true" ]]; then
  echo "PASS: $KEY is true in $bundle defaults"
  exit 0
fi
echo "FAIL: expected $KEY = true in $bundle defaults, found ${value:-<unset>}" >&2
exit 1
