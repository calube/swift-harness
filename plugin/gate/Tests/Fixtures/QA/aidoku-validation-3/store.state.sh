#!/bin/sh
# req-stored-value: the installed app's user defaults must hold
# Downloads.confirmLargeDownloads = true after the store flow switched it on.
set -u
udid="${QA_SIM_UDID:?QA_SIM_UDID is required}"
bundle="${QA_SIM_BUNDLE_ID:-app.aidoku.Aidoku}"
key="Downloads.confirmLargeDownloads"

value="$(xcrun simctl spawn "$udid" defaults read "$bundle" "$key" 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
  echo "FAIL: $key not stored in $bundle defaults: $value"
  exit 1
fi
case "$value" in
  1|true|YES)
    echo "PASS: $key = $value in $bundle defaults"
    exit 0
    ;;
  *)
    echo "FAIL: $key = $value in $bundle defaults, want true"
    exit 1
    ;;
esac
